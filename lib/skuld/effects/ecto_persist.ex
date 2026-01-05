if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.EctoPersist do
    @moduledoc """
    Effect for persisting Ecto operations to the database.

    Provides both single operations (working with changesets or EctoEvents)
    and bulk operations (working with lists of changesets, maps, or EctoEvents).

    ## Single Operations

    Accept either a raw changeset or an EctoEvent:

        user <- EctoPersist.insert(changeset)
        user <- EctoPersist.insert(EctoEvent.insert(changeset))

        user <- EctoPersist.update(changeset)
        user <- EctoPersist.upsert(changeset, conflict_target: :email)
        {:ok, _} <- EctoPersist.delete(user)

    ## Bulk Operations

    Accept lists of changesets, maps, or EctoEvents.
    All elements MUST be for the same schema:

        {count, users} <- EctoPersist.insert_all(User, changesets, returning: true)
        {count, nil}   <- EctoPersist.update_all(User, changesets)
        {count, nil}   <- EctoPersist.delete_all(User, structs)

    ## Handler

        computation
        |> EctoPersist.with_handler(MyApp.Repo)
        |> Comp.run!()

    ## Error Handling

    Operations that fail (e.g., invalid changeset) will throw via the
    Throw effect. Use `Throw.with_handler()` to catch errors:

        comp do
          user <- EctoPersist.insert(changeset)
          return(user)
        catch
          {:invalid_changeset, cs} -> return({:error, cs})
        end
        |> EctoPersist.with_handler(Repo)
        |> Throw.with_handler()
        |> Comp.run!()
    """

    @behaviour Skuld.Comp.IHandler

    import Skuld.Comp.DefOp

    alias Skuld.Comp
    alias Skuld.Comp.Env
    alias Skuld.Comp.Throw, as: ThrowResult
    alias Skuld.Comp.Types
    alias __MODULE__.EctoEvent

    @sig __MODULE__
    @state_key {__MODULE__, :repo}

    #############################################################################
    ## Operation Structs
    #############################################################################

    def_op(Insert, [:input, :opts])
    def_op(Update, [:input, :opts])
    def_op(Upsert, [:input, :opts])
    def_op(Delete, [:input, :opts])
    def_op(InsertAll, [:schema, :entries, :opts])
    def_op(UpdateAll, [:schema, :entries, :opts])
    def_op(UpsertAll, [:schema, :entries, :opts])
    def_op(DeleteAll, [:schema, :entries, :opts])

    #############################################################################
    ## Single Operations
    #############################################################################

    @doc """
    Insert a record from a changeset or EctoEvent.

    Returns the inserted struct on success, throws on error.

    ## Example

        user <- EctoPersist.insert(User.changeset(attrs))
        user <- EctoPersist.insert(EctoEvent.insert(changeset))
    """
    @spec insert(Ecto.Changeset.t() | EctoEvent.t(), keyword()) :: Types.computation()
    def insert(input, opts \\ []) do
      Comp.effect(@sig, %Insert{input: input, opts: opts})
    end

    @doc """
    Update a record from a changeset or EctoEvent.

    Returns the updated struct on success, throws on error.

    ## Example

        user <- EctoPersist.update(User.changeset(user, attrs))
    """
    @spec update(Ecto.Changeset.t() | EctoEvent.t(), keyword()) :: Types.computation()
    def update(input, opts \\ []) do
      Comp.effect(@sig, %Update{input: input, opts: opts})
    end

    @doc """
    Insert or update a record (upsert) from a changeset or EctoEvent.

    Returns the inserted/updated struct on success, throws on error.

    ## Example

        user <- EctoPersist.upsert(changeset, conflict_target: :email)
    """
    @spec upsert(Ecto.Changeset.t() | EctoEvent.t(), keyword()) :: Types.computation()
    def upsert(input, opts \\ []) do
      Comp.effect(@sig, %Upsert{input: input, opts: opts})
    end

    @doc """
    Delete a record from a struct, changeset, or EctoEvent.

    Returns `{:ok, struct}` on success, throws on error.

    ## Example

        {:ok, user} <- EctoPersist.delete(user)
        {:ok, user} <- EctoPersist.delete(EctoEvent.delete(changeset))
    """
    @spec delete(struct() | Ecto.Changeset.t() | EctoEvent.t(), keyword()) :: Types.computation()
    def delete(input, opts \\ []) do
      Comp.effect(@sig, %Delete{input: input, opts: opts})
    end

    #############################################################################
    ## Bulk Operations
    #############################################################################

    @doc """
    Insert multiple records.

    Accepts a list of changesets, maps, or EctoEvents. All must be for
    the same schema.

    Returns `{count, nil | [struct]}` depending on `:returning` option.

    ## Example

        {count, users} <- EctoPersist.insert_all(User, changesets, returning: true)
        {count, nil} <- EctoPersist.insert_all(User, maps)
    """
    @spec insert_all(module(), [Ecto.Changeset.t() | map() | EctoEvent.t()], keyword()) ::
            Types.computation()
    def insert_all(schema, entries, opts \\ []) do
      Comp.effect(@sig, %InsertAll{schema: schema, entries: entries, opts: opts})
    end

    @doc """
    Update multiple records.

    For changesets/EctoEvents: applies each update individually (not truly bulk).
    For maps with `:query` option: uses Repo.update_all with the query.

    Returns `{count, nil | [struct]}`.

    ## Example

        # Update each changeset individually
        {count, users} <- EctoPersist.update_all(User, changesets, returning: true)

        # Bulk update via query
        {count, nil} <- EctoPersist.update_all(User, [], query: query, set: [active: false])
    """
    @spec update_all(module(), [Ecto.Changeset.t() | EctoEvent.t()], keyword()) ::
            Types.computation()
    def update_all(schema, entries, opts \\ []) do
      Comp.effect(@sig, %UpdateAll{schema: schema, entries: entries, opts: opts})
    end

    @doc """
    Upsert multiple records.

    Returns `{count, nil | [struct]}`.

    ## Example

        {count, users} <- EctoPersist.upsert_all(User, changesets,
          conflict_target: :email,
          returning: true
        )
    """
    @spec upsert_all(module(), [Ecto.Changeset.t() | map() | EctoEvent.t()], keyword()) ::
            Types.computation()
    def upsert_all(schema, entries, opts \\ []) do
      Comp.effect(@sig, %UpsertAll{schema: schema, entries: entries, opts: opts})
    end

    @doc """
    Delete multiple records.

    Accepts a list of structs, changesets, or EctoEvents.

    Returns `{count, nil | [struct]}`.

    ## Example

        {count, nil} <- EctoPersist.delete_all(User, users)
    """
    @spec delete_all(module(), [struct() | Ecto.Changeset.t() | EctoEvent.t()], keyword()) ::
            Types.computation()
    def delete_all(schema, entries, opts \\ []) do
      Comp.effect(@sig, %DeleteAll{schema: schema, entries: entries, opts: opts})
    end

    #############################################################################
    ## Handler Installation
    #############################################################################

    @doc """
    Install a scoped EctoPersist handler for a computation.

    ## Example

        computation
        |> EctoPersist.with_handler(MyApp.Repo)
        |> Comp.run!()
    """
    @spec with_handler(Types.computation(), module()) :: Types.computation()
    def with_handler(comp, repo) do
      comp
      |> Comp.scoped(fn env ->
        previous = Env.get_state(env, @state_key)
        modified = Env.put_state(env, @state_key, repo)

        finally_k = fn v, e ->
          restored_env =
            case previous do
              nil -> %{e | state: Map.delete(e.state, @state_key)}
              val -> Env.put_state(e, @state_key, val)
            end

          {v, restored_env}
        end

        {modified, finally_k}
      end)
      |> Comp.with_handler(@sig, &__MODULE__.handle/3)
    end

    #############################################################################
    ## IHandler Implementation
    #############################################################################

    @impl Skuld.Comp.IHandler
    def handle(%Insert{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {changeset, merged_opts} = normalize_input(input, opts)

      case repo.insert(changeset, merged_opts) do
        {:ok, struct} -> k.(struct, env)
        {:error, changeset} -> {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%Update{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {changeset, merged_opts} = normalize_input(input, opts)

      case repo.update(changeset, merged_opts) do
        {:ok, struct} -> k.(struct, env)
        {:error, changeset} -> {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%Upsert{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {changeset, merged_opts} = normalize_input(input, opts)

      case repo.insert_or_update(changeset, merged_opts) do
        {:ok, struct} -> k.(struct, env)
        {:error, changeset} -> {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%Delete{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {struct_or_changeset, merged_opts} = normalize_delete_input(input, opts)

      case repo.delete(struct_or_changeset, merged_opts) do
        {:ok, struct} -> k.({:ok, struct}, env)
        {:error, changeset} -> {%ThrowResult{error: {:delete_failed, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%InsertAll{schema: schema, entries: entries, opts: opts}, env, k) do
      repo = get_repo!(env)

      case validate_and_convert_entries(schema, entries, :insert) do
        {:ok, maps} ->
          result = repo.insert_all(schema, maps, opts)
          k.(result, env)

        {:error, reason} ->
          {%ThrowResult{error: reason}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%UpdateAll{schema: _schema, entries: entries, opts: opts}, env, k) do
      repo = get_repo!(env)

      # Check if this is a query-based bulk update
      case Keyword.pop(opts, :query) do
        {nil, _opts} when entries == [] ->
          # No entries and no query - nothing to do
          k.({0, nil}, env)

        {query, remaining_opts} when not is_nil(query) ->
          # Query-based update
          result = repo.update_all(query, remaining_opts)
          k.(result, env)

        {nil, _opts} ->
          # Update each entry individually
          results =
            Enum.map(entries, fn entry ->
              {changeset, entry_opts} = normalize_input(entry, [])
              repo.update(changeset, entry_opts)
            end)

          successes = Enum.filter(results, &match?({:ok, _}, &1))
          structs = Enum.map(successes, fn {:ok, s} -> s end)

          if Keyword.get(opts, :returning, false) do
            k.({length(successes), structs}, env)
          else
            k.({length(successes), nil}, env)
          end
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%UpsertAll{schema: schema, entries: entries, opts: opts}, env, k) do
      repo = get_repo!(env)

      case validate_and_convert_entries(schema, entries, :upsert) do
        {:ok, maps} ->
          # Use insert_all with on_conflict for upsert behavior
          upsert_opts =
            opts
            |> Keyword.put_new(:on_conflict, :replace_all)
            |> Keyword.put_new(:conflict_target, get_primary_key(schema))

          result = repo.insert_all(schema, maps, upsert_opts)
          k.(result, env)

        {:error, reason} ->
          {%ThrowResult{error: reason}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%DeleteAll{schema: _schema, entries: entries, opts: opts}, env, k) do
      repo = get_repo!(env)

      # Delete each entry individually
      results =
        Enum.map(entries, fn entry ->
          {struct_or_changeset, _entry_opts} = normalize_delete_input(entry, [])
          repo.delete(struct_or_changeset, opts)
        end)

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      structs = Enum.map(successes, fn {:ok, s} -> s end)

      if Keyword.get(opts, :returning, false) do
        k.({length(successes), structs}, env)
      else
        k.({length(successes), nil}, env)
      end
    end

    #############################################################################
    ## Private Helpers
    #############################################################################

    defp get_repo!(env) do
      case Env.get_state(env, @state_key) do
        nil -> raise "EctoPersist handler not installed. Use EctoPersist.with_handler/2"
        repo -> repo
      end
    end

    # Normalize input to {changeset, merged_opts}
    defp normalize_input(%EctoEvent{changeset: cs, opts: event_opts}, call_opts) do
      {cs, Keyword.merge(event_opts, call_opts)}
    end

    defp normalize_input(%Ecto.Changeset{} = cs, opts), do: {cs, opts}

    # Normalize delete input to {struct_or_changeset, merged_opts}
    defp normalize_delete_input(%EctoEvent{changeset: cs, opts: event_opts}, call_opts) do
      {cs, Keyword.merge(event_opts, call_opts)}
    end

    defp normalize_delete_input(%Ecto.Changeset{} = cs, opts), do: {cs, opts}
    defp normalize_delete_input(%{__struct__: _} = struct, opts), do: {struct, opts}

    # Validate all entries are for the same schema and convert to maps
    defp validate_and_convert_entries(_schema, [], _op), do: {:ok, []}

    defp validate_and_convert_entries(schema, entries, _op) do
      maps =
        Enum.map(entries, fn
          %EctoEvent{changeset: cs} -> changeset_to_map(cs)
          %Ecto.Changeset{} = cs -> changeset_to_map(cs)
          %{} = map -> map
        end)

      # Validate schema consistency
      entry_schemas =
        Enum.map(entries, fn
          %EctoEvent{changeset: %Ecto.Changeset{data: %s{}}} -> s
          %Ecto.Changeset{data: %s{}} -> s
          %{} -> schema
        end)
        |> Enum.uniq()

      case entry_schemas do
        [^schema] ->
          {:ok, maps}

        [single] when single != schema ->
          {:error, {:schema_mismatch, expected: schema, got: single}}

        multiple ->
          {:error, {:mixed_schemas, schemas: multiple}}
      end
    end

    defp changeset_to_map(%Ecto.Changeset{} = cs) do
      cs
      |> Ecto.Changeset.apply_changes()
      |> Map.from_struct()
      |> Map.drop([:__meta__])
    end

    defp get_primary_key(schema) do
      case schema.__schema__(:primary_key) do
        [key] -> key
        keys -> keys
      end
    end
  end
end
