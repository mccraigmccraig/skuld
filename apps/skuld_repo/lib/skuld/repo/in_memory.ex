# Closed-world stateful in-memory Repo handler for tests. Recommended default.
#
# Thin wrapper around DoubleDown.Repo.InMemory providing skuld's
# effect-based `with_handler/3` API.
#
defmodule Skuld.Repo.InMemory do
  @moduledoc """
  Closed-world stateful in-memory Repo handler for tests. **Recommended default.**

  Thin wrapper around `DoubleDown.Repo.InMemory` that provides
  skuld's effect-based `with_handler/3` API. The state is the complete
  truth — if a record isn't in the store, it doesn't exist. This makes
  the adapter authoritative for all bare-schema operations without
  needing a fallback function.

  ## Usage

      alias Skuld.Repo

      # Basic — all bare-schema reads work without fallback:
      comp
      |> Repo.InMemory.with_handler(Repo.InMemory.new())
      |> Comp.run!()

      # With seed data:
      state = Repo.InMemory.new(seed: [%User{id: 1, name: "Alice"}])
      comp
      |> Repo.InMemory.with_handler(state)
      |> Comp.run!()

  ## Authoritative operations (bare schema queryables)

  | Category | Operations | Behaviour |
  |----------|-----------|-----------|
  | **Writes** | `insert`, `update`, `delete`, bang variants | Store in state |
  | **PK reads** | `get`, `get!` | `nil`/raise on miss (no fallback) |
  | **Clause reads** | `get_by`, `get_by!` | Scan and filter |
  | **Collection** | `all`, `one`/`one!`, `exists?` | Scan state |
  | **Aggregates** | `aggregate` | Compute from state |
  | **Bulk writes** | `insert_all`, `delete_all`, `update_all` | Modify state |
  | **Preload** | `preload` | Resolve from store |
  | **Reload** | `reload`, `reload!` | Re-fetch from store |
  | **Transactions** | `transact`, `rollback` | Snapshot + restore on rollback |

  ## Ecto.Query fallback

  Operations with `Ecto.Query` queryables (containing `where`,
  `join`, `select` etc.) cannot be evaluated in-memory. These fall
  through to the fallback function, or raise with a clear error.

  ## Extracting Final State

  Use the `:output` option to access the final handler state:

      {result, final_store} =
        comp
        |> Repo.InMemory.with_handler(Repo.InMemory.new(),
          output: fn result, state -> {result, state.handler_state} end
        )
        |> Comp.run!()

  ## Fallback function

  The optional fallback function handles operations the closed-world
  store cannot service (e.g. `Ecto.Query` queryables). It receives
  `(operation, args, state)` — the skuld-idiomatic 3-arity convention.

  ## When to use which Repo fake

  | Fake | State | Best for |
  |------|-------|----------|
  | **`Repo.InMemory`** | **Complete store** | **All bare-schema reads; ExMachina** |
  | `Repo.OpenInMemory` | Partial store | PK reads in state, fallback for rest |
  | `Repo.Stub` | None | Fire-and-forget writes, canned reads |
  """

  alias Skuld.Effects.Port
  alias DoubleDown.Repo.InMemory, as: DDInMemory

  @type store :: DDInMemory.store()

  @doc """
  Create a new InMemory state map.

  ## Options

    * `:seed` - a list of structs to pre-populate the store
    * `:fallback_fn` - a 3-arity function `(operation, args, state) -> result`
      for operations the closed-world store cannot service (e.g. Ecto.Query).

  ## Examples

      Repo.InMemory.new()
      Repo.InMemory.new(seed: [%User{id: 1, name: "Alice"}])
      Repo.InMemory.new(
        seed: [%User{id: 1, name: "Alice"}],
        fallback_fn: fn
          :all, [%Ecto.Query{}], _state -> []
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

    DDInMemory.new(seed_records, dd_opts)
  end

  @doc """
  Convert a list of structs into the nested state map for seeding.
  """
  @spec seed(list(struct())) :: store()
  defdelegate seed(records), to: DDInMemory

  @doc """
  Install the closed-world in-memory Repo handler for a computation.

  ## Options

  All options from `Port.with_stateful_handler/4` are supported:

    * `:log` — enable dispatch logging
    * `:output` — transform `(result, %Port.State{}) -> output` on scope exit.
  """
  @spec with_handler(Skuld.Comp.Types.computation(), store(), keyword()) ::
          Skuld.Comp.Types.computation()
  def with_handler(comp, initial_store \\ %{}, opts \\ []) do
    Port.with_stateful_handler(comp, initial_store, &DDInMemory.dispatch/4, opts)
  end

  @doc """
  Returns the stateful handler function.

  The function has the signature `(contract, operation, args, state) -> {result, new_state}`.
  """
  def handler, do: &DDInMemory.dispatch/4
end
