# Test executor for Port.Repo that provides default return values.
#
# Logging is handled by Port's built-in :log option — each dispatch
# records a {mod, name, args, result} 4-tuple in Port.State.log.
#
# ## Usage
#
#     comp
#     |> Port.with_handler(
#       %{Port.Repo => {:effectful, Port.Repo.Test}},
#       log: true,
#       output: fn r, state -> {r, state.log} end
#     )
#     |> Throw.with_handler()
#     |> Comp.run!()
#     #=> {result, [{Port.Repo, :insert, [changeset], {:ok, struct}}, ...]}
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.Test do
    @moduledoc """
    Test executor for `Port.Repo` with sensible defaults for all operations.

    Write operations (`insert`, `update`, `delete`) apply changeset changes
    to produce a struct and return `{:ok, struct}`. Read operations return
    sensible empty defaults (`nil`, `[]`, `false`). Bulk operations return
    `{0, nil}`.

    ## Log Format

    When Port's `:log` option is enabled, each dispatch records a 4-tuple
    `{module, operation, args_list, return_value}` in `Port.State.log`:

        {Port.Repo, :insert, [changeset], {:ok, %User{name: "Alice"}}}
        {Port.Repo, :get, [User, 42], nil}
        {Port.Repo, :delete, [record], {:ok, record}}

    ## Usage

        alias Skuld.Effects.Port
        alias Skuld.Effects.Port.Repo

        {result, log} =
          comp
          |> Port.with_handler(
            %{Repo => {:effectful, Repo.Test}},
            log: true,
            output: fn result, state -> {result, state.log} end
          )
          |> Throw.with_handler()
          |> Comp.run!()

        # log is [{Repo, :insert, [changeset], {:ok, struct}}, ...]
    """

    alias Skuld.Comp
    alias Skuld.Effects.Port.Repo

    @behaviour Repo.Effectful

    # -----------------------------------------------------------------
    # Write Operations
    # -----------------------------------------------------------------

    @impl true
    def insert(changeset) do
      Comp.pure({:ok, safe_apply_changes(changeset)})
    end

    @impl true
    def update(changeset) do
      Comp.pure({:ok, safe_apply_changes(changeset)})
    end

    @impl true
    def delete(record) do
      Comp.pure({:ok, record})
    end

    # -----------------------------------------------------------------
    # Bulk Operations
    # -----------------------------------------------------------------

    @impl true
    def update_all(_queryable, _updates, _opts) do
      Comp.pure({0, nil})
    end

    @impl true
    def delete_all(_queryable, _opts) do
      Comp.pure({0, nil})
    end

    # -----------------------------------------------------------------
    # Read Operations
    # -----------------------------------------------------------------

    @impl true
    def get(_queryable, _id), do: Comp.pure(nil)

    @impl true
    def get!(_queryable, _id), do: Comp.pure(nil)

    @impl true
    def get_by(_queryable, _clauses), do: Comp.pure(nil)

    @impl true
    def get_by!(_queryable, _clauses), do: Comp.pure(nil)

    @impl true
    def one(_queryable), do: Comp.pure(nil)

    @impl true
    def one!(_queryable), do: Comp.pure(nil)

    @impl true
    def all(_queryable), do: Comp.pure([])

    @impl true
    def exists?(_queryable), do: Comp.pure(false)

    @impl true
    def aggregate(_queryable, _aggregate_fn, _field), do: Comp.pure(nil)

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------

    defp safe_apply_changes(%Ecto.Changeset{} = changeset) do
      Ecto.Changeset.apply_changes(changeset)
    end
  end
end
