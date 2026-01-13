if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.ChangesetPersist.Ecto do
    @moduledoc """
    Ecto Repo handler for ChangesetPersist effect.

    Uses an Ecto Repo to persist changesets to the database.

    ## Usage

        computation
        |> ChangesetPersist.Ecto.with_handler(MyApp.Repo)
        |> Comp.run!()

    ## Error Handling

    Operations that fail (e.g., invalid changeset) will throw via the
    Throw effect. Use `Throw.with_handler()` to catch errors:

        comp do
          user <- ChangesetPersist.insert(changeset)
          return(user)
        catch
          {:invalid_changeset, cs} -> return({:error, cs})
        end
        |> ChangesetPersist.Ecto.with_handler(Repo)
        |> Throw.with_handler()
        |> Comp.run!()
    """

    @behaviour Skuld.Comp.IHandler

    alias Skuld.Comp
    alias Skuld.Comp.Env
    alias Skuld.Comp.Throw, as: ThrowResult
    alias Skuld.Comp.Types
    alias Skuld.Effects.ChangeEvent
    alias Skuld.Effects.ChangesetPersist

    @state_key {ChangesetPersist, :repo}

    #############################################################################
    ## Handler Installation
    #############################################################################

    @doc """
    Install a scoped ChangesetPersist Ecto handler for a computation.

    ## Example

        computation
        |> ChangesetPersist.Ecto.with_handler(MyApp.Repo)
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
      |> Comp.with_handler(ChangesetPersist.sig(), &__MODULE__.handle/3)
    end

    #############################################################################
    ## IHandler Implementation
    #############################################################################

    @impl Skuld.Comp.IHandler
    def handle(%ChangesetPersist.Insert{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {changeset, merged_opts} = normalize_input(input, opts)

      case repo.insert(changeset, merged_opts) do
        {:ok, struct} -> k.(struct, env)
        {:error, changeset} -> {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%ChangesetPersist.Update{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {changeset, merged_opts} = normalize_input(input, opts)

      case repo.update(changeset, merged_opts) do
        {:ok, struct} -> k.(struct, env)
        {:error, changeset} -> {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%ChangesetPersist.Upsert{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {changeset, merged_opts} = normalize_input(input, opts)

      case repo.insert_or_update(changeset, merged_opts) do
        {:ok, struct} -> k.(struct, env)
        {:error, changeset} -> {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%ChangesetPersist.Delete{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {struct_or_changeset, merged_opts} = normalize_delete_input(input, opts)

      case repo.delete(struct_or_changeset, merged_opts) do
        {:ok, struct} -> k.({:ok, struct}, env)
        {:error, changeset} -> {%ThrowResult{error: {:delete_failed, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandler
    def handle(%ChangesetPersist.InsertAll{schema: schema, entries: entries, opts: opts}, env, k) do
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
    def handle(
          %ChangesetPersist.UpdateAll{schema: _schema, entries: entries, opts: opts},
          env,
          k
        ) do
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
    def handle(
          %ChangesetPersist.UpsertAll{schema: schema, entries: entries, opts: opts},
          env,
          k
        ) do
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
    def handle(
          %ChangesetPersist.DeleteAll{schema: _schema, entries: entries, opts: opts},
          env,
          k
        ) do
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
        nil ->
          raise "ChangesetPersist.Ecto handler not installed. Use ChangesetPersist.Ecto.with_handler/2"

        repo ->
          repo
      end
    end

    # Normalize input to {changeset, merged_opts}
    defp normalize_input(%ChangeEvent{changeset: cs, opts: event_opts}, call_opts) do
      {cs, Keyword.merge(event_opts, call_opts)}
    end

    defp normalize_input(%Ecto.Changeset{} = cs, opts), do: {cs, opts}

    # Normalize delete input to {struct_or_changeset, merged_opts}
    defp normalize_delete_input(%ChangeEvent{changeset: cs, opts: event_opts}, call_opts) do
      {cs, Keyword.merge(event_opts, call_opts)}
    end

    defp normalize_delete_input(%Ecto.Changeset{} = cs, opts), do: {cs, opts}
    defp normalize_delete_input(%{__struct__: _} = struct, opts), do: {struct, opts}

    # Validate all entries are for the same schema and convert to maps
    defp validate_and_convert_entries(_schema, [], _op), do: {:ok, []}

    defp validate_and_convert_entries(schema, entries, _op) do
      maps =
        Enum.map(entries, fn
          %ChangeEvent{changeset: cs} -> changeset_to_map(cs)
          %Ecto.Changeset{} = cs -> changeset_to_map(cs)
          %{} = map -> map
        end)

      # Validate schema consistency
      entry_schemas =
        Enum.map(entries, fn
          %ChangeEvent{changeset: %Ecto.Changeset{data: %s{}}} -> s
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
