# Open-world stateful in-memory Repo handler for tests.
#
# Thin wrapper around DoubleDown.Repo.OpenInMemory providing skuld's
# effect-based `with_handler/3` API. See Repo.InMemory for the
# recommended closed-world variant.
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.OpenInMemory do
    @moduledoc """
    Open-world stateful in-memory Repo handler for tests.

    Thin wrapper around `DoubleDown.Repo.OpenInMemory` that provides
    skuld's effect-based `with_handler/3` API. The underlying DD fake
    handles all Repo operations — writes mutate state, PK reads check
    state then fallback, everything else goes to fallback.

    For most use cases, prefer `Repo.InMemory` (closed-world) which
    is authoritative for all bare-schema reads without a fallback.
    Use `OpenInMemory` when the state is deliberately partial.

    ## Usage

        alias Skuld.Effects.Port.Repo

        # Basic — PK reads only, no fallback:
        comp
        |> Repo.OpenInMemory.with_handler(Repo.OpenInMemory.new())
        |> Comp.run!()

        # With seed data and fallback:
        state = Repo.OpenInMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn
            :all, [User], state ->
              Map.get(state, User, %{}) |> Map.values()
            :get_by, [User, [email: "alice@example.com"]], _state ->
              %User{id: 1}
          end
        )
        comp
        |> Repo.OpenInMemory.with_handler(state)
        |> Comp.run!()

    ## Extracting Final State

    Use the `:output` option to access the final handler state:

        {result, final_store} =
          comp
          |> Repo.OpenInMemory.with_handler(Repo.OpenInMemory.new(),
            output: fn result, state -> {result, state.handler_state} end
          )
          |> Comp.run!()

    ## Fallback function

    The fallback function receives `(operation, args, state)` where
    `state` is the clean store map (without internal keys). If it raises
    `FunctionClauseError`, dispatch falls through to an error.

    This is the skuld-idiomatic 3-arity convention. The wrapper adapts
    it to DD's 4-arity `(contract, operation, args, state)` convention
    internally.
    """

    alias Skuld.Effects.Port
    alias DoubleDown.Repo.OpenInMemory, as: DDOpenInMemory

    @type store :: DDOpenInMemory.store()

    @doc """
    Create a new OpenInMemory state map.

    ## Options

      * `:seed` - a list of structs to pre-populate the store
      * `:fallback_fn` - a 3-arity function `(operation, args, state) -> result`
        that handles operations the state cannot answer authoritatively.

    ## Examples

        Repo.OpenInMemory.new()
        Repo.OpenInMemory.new(seed: [%User{id: 1, name: "Alice"}])
        Repo.OpenInMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn
            :all, [User], state -> Map.get(state, User, %{}) |> Map.values()
          end
        )
    """
    @spec new(keyword()) :: store()
    def new(opts \\ []) do
      seed_records = Keyword.get(opts, :seed, [])
      skuld_fallback = Keyword.get(opts, :fallback_fn, nil)

      dd_opts =
        if skuld_fallback do
          [fallback_fn: fn _contract, op, args, state -> skuld_fallback.(op, args, state) end]
        else
          []
        end

      DDOpenInMemory.new(seed_records, dd_opts)
    end

    @doc """
    Convert a list of structs into the nested state map for seeding.
    """
    @spec seed(list(struct())) :: store()
    defdelegate seed(records), to: DDOpenInMemory

    @doc """
    Install the open-world in-memory Repo handler for a computation.

    ## Options

    All options from `Port.with_stateful_handler/4` are supported:

      * `:log` — enable dispatch logging
      * `:output` — transform `(result, %Port.State{}) -> output` on scope exit.
    """
    @spec with_handler(Skuld.Comp.Types.computation(), store(), keyword()) ::
            Skuld.Comp.Types.computation()
    def with_handler(comp, initial_store \\ %{}, opts \\ []) do
      Port.with_stateful_handler(comp, initial_store, &DDOpenInMemory.dispatch/4, opts)
    end

    @doc """
    Returns the stateful handler function.

    The function has the signature `(contract, operation, args, state) -> {result, new_state}`.
    """
    def handler, do: &DDOpenInMemory.dispatch/4
  end
end
