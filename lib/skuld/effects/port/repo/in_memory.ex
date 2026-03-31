# Stateful in-memory Repo handler for tests.
#
# Provides read-after-write consistency for PK-based lookups. Non-PK reads
# go through an optional fallback function, or raise.
#
# ## Usage
#
#     alias Skuld.Effects.Port.Repo
#
#     comp
#     |> Repo.InMemory.with_handler(Repo.InMemory.new())
#     |> Throw.with_handler()
#     |> Comp.run!()
#
#     # With seeded data and a fallback function
#     state = Repo.InMemory.new(
#       seed: [%User{id: 1, name: "Alice"}],
#       fallback_fn: fn
#         :all, [User] -> [%User{id: 1, name: "Alice"}]
#       end
#     )
#
#     comp
#     |> Repo.InMemory.with_handler(state)
#     |> Throw.with_handler()
#     |> Comp.run!()
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.InMemory do
    @moduledoc """
    Stateful in-memory Repo handler for tests.

    Provides a `Port.with_stateful_handler/4`-based handler for `Port.Repo`
    operations. State is a nested map keyed by `schema_module => %{primary_key => struct}`,
    giving read-after-write consistency for PK-based lookups within a
    single computation.

    ## State Shape

        %{
          MyApp.User => %{
            1 => %MyApp.User{id: 1, name: "Alice"},
            2 => %MyApp.User{id: 2, name: "Bob"}
          },
          MyApp.Post => %{
            1 => %MyApp.Post{id: 1, title: "Hello"}
          }
        }

    ## 3-Stage Read Dispatch

    The InMemory adapter can only answer authoritatively for operations where
    the state definitively contains the answer. For PK-based reads (`get`,
    `get!`), if a record is found in state it is returned. If not found, the
    adapter cannot know whether the record exists in the _logical_ store —
    it falls through to the fallback function, or raises.

    For all other reads (`get_by`, `one`, `all`, `exists?`, `aggregate`, etc.)
    the state is never authoritative — these always go through the fallback
    function, or raise.

    The dispatch stages are:

    1. **State lookup** (PK reads only) — if the record is in state, return it
    2. **Fallback function** — an optional user-supplied function that handles
       operations the state cannot answer. Receives `(operation, args, state)`
       where `state` is the clean store map (without internal keys), and
       returns the result. If it raises `FunctionClauseError`, falls through
       to stage 3.
    3. **Raise** — a clear error explaining that InMemory cannot service the
       operation, suggesting the fallback function as the escape hatch.

    ## Usage

        alias Skuld.Effects.Port
        alias Skuld.Effects.Port.Repo

        # Basic — PK reads only, no fallback:
        comp
        |> Repo.InMemory.with_handler(Repo.InMemory.new())
        |> Throw.with_handler()
        |> Comp.run!()

        # With seed data and fallback:
        state = Repo.InMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn
            :all, [User], state ->
              Map.get(state, User, %{}) |> Map.values()
            :get_by, [User, [email: "alice@example.com"]], _state ->
              %User{id: 1}
          end
        )
        comp
        |> Repo.InMemory.with_handler(state)
        |> Throw.with_handler()
        |> Comp.run!()

    ## Extracting Final State

    Use the `:output` option to access the final handler state:

        {result, final_store} =
          comp
          |> Repo.InMemory.with_handler(Repo.InMemory.new(),
            output: fn result, state -> {result, state.handler_state} end
          )
          |> Throw.with_handler()
          |> Comp.run!()

    ## Differences from Repo.Test

    `Repo.Test` is stateless — writes apply changesets and return `{:ok, struct}`
    but nothing is stored. There is no read-after-write consistency.

    `Repo.InMemory` is stateful — writes store records in state, and subsequent
    PK-based reads can find them. Non-PK reads require a fallback function.
    Use `Repo.InMemory` when your test needs read-after-write consistency.
    Use `Repo.Test` when you only need fire-and-forget writes.

    ## Auto-incrementing IDs

    When inserting a changeset for a record with a `nil` id, `Repo.InMemory`
    assigns a positive integer id based on the count of existing records of
    that schema type. This mirrors Ecto's auto-increment behaviour.

    ## Supported Operations

    - **Writes (authoritative):** `insert`, `update`, `delete` — always handled
      by the state
    - **PK reads (3-stage):** `get`, `get!` — check state first, then fallback,
      then error
    - **Non-PK reads (2-stage):** `get_by`, `get_by!`, `one`, `one!`, `all`,
      `exists?`, `aggregate` — fallback or error
    - **Bulk (2-stage):** `update_all`, `delete_all` — fallback or error
    """

    alias Skuld.Effects.Port
    alias Skuld.Effects.Port.Repo

    @type store :: %{optional(module()) => %{optional(term()) => struct()}}

    @fallback_fn_key :__fallback_fn__

    @doc """
    Create a new InMemory state map.

    ## Options

      * `:seed` - a list of structs to pre-populate the store
      * `:fallback_fn` - a 3-arity function `(operation, args, state) -> result`
        that handles operations the state cannot answer authoritatively. The
        `state` argument is the clean store map (without internal keys like
        `:__fallback_fn__`), so the fallback can compose canned data with
        records inserted during the test. If the function raises
        `FunctionClauseError`, dispatch falls through to an error.

    ## Examples

        # Empty state, no fallback
        Repo.InMemory.new()

        # Seeded with fallback that uses state
        Repo.InMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn
            :all, [User], state ->
              Map.get(state, User, %{}) |> Map.values()
          end
        )
    """
    @spec new(keyword()) :: store()
    def new(opts \\ []) do
      seed_records = Keyword.get(opts, :seed, [])
      fallback_fn = Keyword.get(opts, :fallback_fn, nil)

      store = seed(seed_records)

      if fallback_fn do
        Map.put(store, @fallback_fn_key, fallback_fn)
      else
        store
      end
    end

    @doc """
    Convert a list of structs into the nested state map for seeding.

    ## Example

        Repo.InMemory.seed([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"}
        ])
        #=> %{User => %{1 => %User{id: 1, name: "Alice"},
        #               2 => %User{id: 2, name: "Bob"}}}
    """
    @spec seed(list(struct())) :: store()
    def seed(records) when is_list(records) do
      Enum.reduce(records, %{}, fn record, store ->
        schema = record.__struct__
        id = get_primary_key(record)
        put_record(store, schema, id, record)
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
        |> Repo.InMemory.with_handler(Repo.InMemory.new())
        |> Throw.with_handler()
        |> Comp.run!()

        # With seeded data and output
        state = Repo.InMemory.new(seed: [%User{id: 1, name: "Alice"}])

        {result, store} =
          comp
          |> Repo.InMemory.with_handler(state,
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
    # Write operations — always authoritative
    # -----------------------------------------------------------------

    defp dispatch(Repo.Contract, :insert, [changeset], store) do
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

      {{:ok, record}, put_record(store, schema, id, record)}
    end

    defp dispatch(Repo.Contract, :update, [changeset], store) do
      record = safe_apply_changes(changeset)
      schema = record.__struct__
      id = get_primary_key(record)
      {{:ok, record}, put_record(store, schema, id, record)}
    end

    defp dispatch(Repo.Contract, :delete, [record], store) do
      schema = record.__struct__
      id = get_primary_key(record)
      {{:ok, record}, delete_record(store, schema, id)}
    end

    # -----------------------------------------------------------------
    # PK reads — 3-stage: state -> fallback -> error
    # -----------------------------------------------------------------

    defp dispatch(Repo.Contract, :get, [queryable, id] = args, store) do
      schema = extract_schema(queryable)

      case get_record(store, schema, id) do
        nil -> try_fallback(store, :get, args)
        record -> {record, store}
      end
    end

    defp dispatch(Repo.Contract, :get!, [queryable, id] = args, store) do
      schema = extract_schema(queryable)

      case get_record(store, schema, id) do
        nil -> try_fallback(store, :get!, args)
        record -> {record, store}
      end
    end

    # -----------------------------------------------------------------
    # Non-PK reads — 2-stage: fallback -> error
    # -----------------------------------------------------------------

    defp dispatch(Repo.Contract, :get_by, args, store),
      do: dispatch_via_fallback(:get_by, args, store)

    defp dispatch(Repo.Contract, :get_by!, args, store),
      do: dispatch_via_fallback(:get_by!, args, store)

    defp dispatch(Repo.Contract, :one, args, store),
      do: dispatch_via_fallback(:one, args, store)

    defp dispatch(Repo.Contract, :one!, args, store),
      do: dispatch_via_fallback(:one!, args, store)

    defp dispatch(Repo.Contract, :all, args, store),
      do: dispatch_via_fallback(:all, args, store)

    defp dispatch(Repo.Contract, :exists?, args, store),
      do: dispatch_via_fallback(:exists?, args, store)

    defp dispatch(Repo.Contract, :aggregate, args, store),
      do: dispatch_via_fallback(:aggregate, args, store)

    # -----------------------------------------------------------------
    # Bulk operations — 2-stage: fallback -> error
    # -----------------------------------------------------------------

    defp dispatch(Repo.Contract, :update_all, args, store),
      do: dispatch_via_fallback(:update_all, args, store)

    defp dispatch(Repo.Contract, :delete_all, args, store),
      do: dispatch_via_fallback(:delete_all, args, store)

    # -----------------------------------------------------------------
    # Fallback dispatch
    # -----------------------------------------------------------------

    defp dispatch_via_fallback(operation, args, store) do
      try_fallback(store, operation, args)
    end

    defp try_fallback(store, operation, args) do
      case Map.get(store, @fallback_fn_key) do
        nil ->
          raise_no_fallback(operation, args)

        fallback_fn when is_function(fallback_fn, 3) ->
          clean_state = Map.delete(store, @fallback_fn_key)

          try do
            {fallback_fn.(operation, args, clean_state), store}
          rescue
            FunctionClauseError -> raise_no_fallback(operation, args)
          end
      end
    end

    defp raise_no_fallback(operation, args) do
      raise ArgumentError, """
      Skuld.Effects.Port.Repo.InMemory cannot service :#{operation} with args #{inspect(args)}.

      The InMemory adapter can only answer authoritatively for:
        - Write operations (insert, update, delete)
        - PK-based reads (get, get!) when the record exists in state

      For all other operations, register a fallback function:

          Repo.InMemory.new(
            fallback_fn: fn
              :#{operation}, #{inspect(args)}, _state -> # your result here
            end
          )
      """
    end

    # -----------------------------------------------------------------
    # State access helpers
    # -----------------------------------------------------------------

    defp get_record(store, schema, id) do
      store
      |> Map.get(schema, %{})
      |> Map.get(id)
    end

    defp put_record(store, schema, id, record) do
      schema_map = Map.get(store, schema, %{})
      Map.put(store, schema, Map.put(schema_map, id, record))
    end

    defp delete_record(store, schema, id) do
      case Map.get(store, schema) do
        nil -> store
        schema_map -> Map.put(store, schema, Map.delete(schema_map, id))
      end
    end

    defp records_for_schema(store, schema) do
      store
      |> Map.get(schema, %{})
      |> Map.values()
    end

    # -----------------------------------------------------------------
    # Other helpers
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
        |> records_for_schema(schema)
        |> Enum.map(&get_primary_key/1)
        |> Enum.filter(&is_integer/1)

      case existing_ids do
        [] -> 1
        ids -> Enum.max(ids) + 1
      end
    end
  end
end
