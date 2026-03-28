# Stateful in-memory Repo handler for tests.
#
# Provides read-after-write consistency: insert a record, then get it back
# within the same computation. Built on top of Port.with_stateful_handler.
#
# ## Usage
#
#     alias Skuld.Effects.Port.Repo
#
#     comp
#     |> Repo.InMemory.with_handler(%{})
#     |> Throw.with_handler()
#     |> Comp.run!()
#
#     # With seeded data
#     initial = Repo.InMemory.seed([%User{id: 1, name: "Alice"}])
#
#     comp
#     |> Repo.InMemory.with_handler(initial)
#     |> Throw.with_handler()
#     |> Comp.run!()
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.InMemory do
    @moduledoc """
    Stateful in-memory Repo handler for tests.

    Provides a `Port.with_stateful_handler/4`-based handler for `Port.Repo`
    operations. State is a map keyed by `{schema_module, primary_key}`,
    giving read-after-write consistency within a single computation.

    ## State Shape

        %{
          {MyApp.User, 1} => %MyApp.User{id: 1, name: "Alice"},
          {MyApp.User, 2} => %MyApp.User{id: 2, name: "Bob"}
        }

    ## Seeding Initial State

    Use `seed/1` to convert a list of structs into the state map:

        initial = Repo.InMemory.seed([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"}
        ])

        comp
        |> Repo.InMemory.with_handler(initial)
        |> Throw.with_handler()
        |> Comp.run!()

    ## Extracting Final State

    Use the `:output` option to access the final handler state:

        {result, final_store} =
          comp
          |> Repo.InMemory.with_handler(%{},
            output: fn result, state -> {result, state.handler_state} end
          )
          |> Throw.with_handler()
          |> Comp.run!()

    ## Differences from Repo.Test

    `Repo.Test` is stateless — writes apply changesets and return `{:ok, struct}`
    but nothing is stored. Reads always return defaults (`nil`, `[]`, `false`).

    `Repo.InMemory` is stateful — writes store records in the state map, and
    subsequent reads can find them. Use `Repo.InMemory` when your test needs
    read-after-write consistency (e.g. insert then get). Use `Repo.Test` when
    you only need fire-and-forget writes.

    ## Auto-incrementing IDs

    When inserting a changeset for a record with a `nil` id, `Repo.InMemory`
    assigns a positive integer id based on the count of existing records of
    that schema type. This mirrors Ecto's auto-increment behaviour.

    ## Supported Operations

    All `Port.Repo` operations are supported:

    - **Writes:** `insert`, `update`, `delete`
    - **Reads:** `get`, `get!`, `get_by`, `get_by!`, `one`, `one!`, `all`,
      `exists?`, `aggregate`
    - **Bulk:** `update_all`, `delete_all` (basic implementations — `update_all`
      returns `{0, nil}` since queryable parsing is not supported; `delete_all`
      removes all records of the given schema)
    """

    alias Skuld.Effects.Port
    alias Skuld.Effects.Port.Repo

    @type store :: %{{module(), term()} => struct()}

    @doc """
    Convert a list of structs into the state map for seeding.

    ## Example

        Repo.InMemory.seed([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"}
        ])
        #=> %{{User, 1} => %User{id: 1, name: "Alice"},
        #     {User, 2} => %User{id: 2, name: "Bob"}}
    """
    @spec seed(list(struct())) :: store()
    def seed(records) when is_list(records) do
      Map.new(records, fn record ->
        schema = record.__struct__
        id = get_primary_key(record)
        {{schema, id}, record}
      end)
    end

    @doc """
    Install the in-memory Repo handler for a computation.

    ## Options

    All options from `Port.with_stateful_handler/4` are supported:

      * `:log` — enable dispatch logging
      * `:output` — transform `(result, %Port.State{}) -> output` on scope exit.
        `state.handler_state` contains the final store map.

    ## Example

        comp
        |> Repo.InMemory.with_handler(%{})
        |> Throw.with_handler()
        |> Comp.run!()

        # With seeded data and output
        initial = Repo.InMemory.seed([%User{id: 1, name: "Alice"}])

        {result, store} =
          comp
          |> Repo.InMemory.with_handler(initial,
            output: fn result, state -> {result, state.handler_state} end
          )
          |> Throw.with_handler()
          |> Comp.run!()
    """
    @spec with_handler(Skuld.Comp.Types.computation(), store(), keyword()) ::
            Skuld.Comp.Types.computation()
    def with_handler(comp, initial_store \\ %{}, opts \\ []) do
      Port.with_stateful_handler(comp, initial_store, &dispatch/4, opts)
    end

    @doc """
    Returns the stateful handler function.

    Useful when building custom handler compositions. The function has
    the signature `(mod, name, args, state) -> {result, new_state}`.
    """
    @spec handler() :: Port.stateful_handler()
    def handler, do: &dispatch/4

    # -----------------------------------------------------------------
    # Dispatch — routes Repo operations to state operations
    # -----------------------------------------------------------------

    # Write operations

    defp dispatch(Repo, :insert, [changeset], store) do
      record = safe_apply_changes(changeset)
      schema = record.__struct__
      id = get_primary_key(record)

      # Auto-assign ID if nil
      {id, record} =
        if id == nil do
          new_id = next_id(store, schema)
          record = put_primary_key(record, new_id)
          {new_id, record}
        else
          {id, record}
        end

      {{:ok, record}, Map.put(store, {schema, id}, record)}
    end

    defp dispatch(Repo, :update, [changeset], store) do
      record = safe_apply_changes(changeset)
      schema = record.__struct__
      id = get_primary_key(record)
      {{:ok, record}, Map.put(store, {schema, id}, record)}
    end

    defp dispatch(Repo, :delete, [record], store) do
      schema = record.__struct__
      id = get_primary_key(record)
      {{:ok, record}, Map.delete(store, {schema, id})}
    end

    # Bulk operations

    defp dispatch(Repo, :update_all, [_queryable, _updates, _opts], store) do
      # Queryable parsing is out of scope — return {0, nil}
      {{0, nil}, store}
    end

    defp dispatch(Repo, :delete_all, [queryable, _opts], store) do
      schema = extract_schema(queryable)
      {deleted, remaining} = Map.split_with(store, fn {{s, _id}, _v} -> s == schema end)
      count = map_size(deleted)
      {{count, nil}, Map.new(remaining)}
    end

    # Read operations

    defp dispatch(Repo, :get, [queryable, id], store) do
      schema = extract_schema(queryable)
      {Map.get(store, {schema, id}), store}
    end

    defp dispatch(Repo, :get!, [queryable, id], store) do
      schema = extract_schema(queryable)
      {Map.get(store, {schema, id}), store}
    end

    defp dispatch(Repo, :get_by, [queryable, clauses], store) do
      schema = extract_schema(queryable)
      clauses_list = to_keyword(clauses)
      result = find_by_clauses(store, schema, clauses_list)
      {result, store}
    end

    defp dispatch(Repo, :get_by!, [queryable, clauses], store) do
      schema = extract_schema(queryable)
      clauses_list = to_keyword(clauses)
      result = find_by_clauses(store, schema, clauses_list)
      {result, store}
    end

    defp dispatch(Repo, :one, [queryable], store) do
      schema = extract_schema(queryable)

      result =
        store
        |> records_for_schema(schema)
        |> List.first()

      {result, store}
    end

    defp dispatch(Repo, :one!, [queryable], store) do
      schema = extract_schema(queryable)

      result =
        store
        |> records_for_schema(schema)
        |> List.first()

      {result, store}
    end

    defp dispatch(Repo, :all, [queryable], store) do
      schema = extract_schema(queryable)
      {records_for_schema(store, schema), store}
    end

    defp dispatch(Repo, :exists?, [queryable], store) do
      schema = extract_schema(queryable)
      exists = Enum.any?(store, fn {{s, _id}, _v} -> s == schema end)
      {exists, store}
    end

    defp dispatch(Repo, :aggregate, [queryable, aggregate, field], store) do
      schema = extract_schema(queryable)
      records = records_for_schema(store, schema)

      result =
        case aggregate do
          :count ->
            length(records)

          :sum ->
            records |> Enum.map(&Map.get(&1, field, 0)) |> Enum.sum()

          :avg ->
            values = Enum.map(records, &Map.get(&1, field, 0))

            if values == [] do
              nil
            else
              Enum.sum(values) / length(values)
            end

          :min ->
            records |> Enum.map(&Map.get(&1, field)) |> Enum.min(fn -> nil end)

          :max ->
            records |> Enum.map(&Map.get(&1, field)) |> Enum.max(fn -> nil end)

          _ ->
            nil
        end

      {result, store}
    end

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------

    defp safe_apply_changes(%Ecto.Changeset{} = changeset) do
      Ecto.Changeset.apply_changes(changeset)
    end

    defp extract_schema(queryable) when is_atom(queryable), do: queryable

    defp extract_schema(%Ecto.Query{from: %Ecto.Query.FromExpr{source: {_table, schema}}})
         when is_atom(schema) and not is_nil(schema) do
      schema
    end

    defp extract_schema(queryable), do: queryable

    defp get_primary_key(record) do
      schema = record.__struct__

      if function_exported?(schema, :__schema__, 1) do
        case schema.__schema__(:primary_key) do
          [pk_field] -> Map.get(record, pk_field)
          # Composite keys — use a tuple
          fields when is_list(fields) -> List.to_tuple(Enum.map(fields, &Map.get(record, &1)))
          _ -> Map.get(record, :id)
        end
      else
        Map.get(record, :id)
      end
    end

    defp put_primary_key(record, value) do
      schema = record.__struct__

      if function_exported?(schema, :__schema__, 1) do
        case schema.__schema__(:primary_key) do
          [pk_field] -> Map.put(record, pk_field, value)
          _ -> Map.put(record, :id, value)
        end
      else
        Map.put(record, :id, value)
      end
    end

    defp next_id(store, schema) do
      existing_ids =
        store
        |> Enum.filter(fn {{s, _id}, _v} -> s == schema end)
        |> Enum.map(fn {{_s, id}, _v} -> id end)
        |> Enum.filter(&is_integer/1)

      case existing_ids do
        [] -> 1
        ids -> Enum.max(ids) + 1
      end
    end

    defp records_for_schema(store, schema) do
      store
      |> Enum.filter(fn {{s, _id}, _v} -> s == schema end)
      |> Enum.map(fn {_key, record} -> record end)
    end

    defp find_by_clauses(store, schema, clauses) do
      store
      |> records_for_schema(schema)
      |> Enum.find(fn record ->
        Enum.all?(clauses, fn {field, value} ->
          Map.get(record, field) == value
        end)
      end)
    end

    defp to_keyword(clauses) when is_map(clauses), do: Map.to_list(clauses)
    defp to_keyword(clauses) when is_list(clauses), do: clauses
  end
end
