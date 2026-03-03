# Unified Ecto handler for the DB effect.
#
# Handles both write operations (insert, update, upsert, delete + bulk variants)
# and transaction operations (transact, rollback) through a single handler.
#
# ## Usage
#
#     computation
#     |> DB.Ecto.with_handler(MyApp.Repo)
#     |> Comp.run!()
#
# ## Transactions with Writes
#
#     comp do
#       result <- DB.transact(comp do
#         user <- DB.insert(user_changeset)
#         order <- DB.insert(order_changeset)
#         return({user, order})
#       end)
#       return(result)
#     end
#     |> DB.Ecto.with_handler(MyApp.Repo)
#     |> Comp.run!()
#
# ## Options
#
# Transaction options (`:timeout`, `:isolation`) can be passed via
# `with_handler/3`.
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.DB.Ecto do
    @moduledoc false

    @behaviour Skuld.Comp.IHandle
    @behaviour Skuld.Comp.IInstall

    alias Skuld.Comp
    alias Skuld.Comp.Env
    alias Skuld.Comp.ISentinel
    alias Skuld.Comp.Throw, as: ThrowResult
    alias Skuld.Comp.Types
    alias Skuld.Effects.ChangeEvent
    alias Skuld.Effects.DB

    @state_key {DB, :ecto_config}

    #############################################################################
    ## Handler Installation
    #############################################################################

    @doc """
    Install a scoped DB Ecto handler for a computation.

    Handles all DB operations (writes and transactions) using the given Ecto Repo.

    ## Options

    All options except `:preserve_state_on_rollback` are passed through to
    `Repo.transaction/2` (e.g. `:timeout`, `:isolation`).

      * `:preserve_state_on_rollback` - list of `env.state` keys whose values
        should be kept from the post-transaction env even when the transaction
        rolls back. By default, **all** env state accumulated inside a rolled-back
        transaction is discarded (restored to pre-transaction values). Use this
        to opt specific effects out of rollback — e.g. error counters or metrics
        that should survive.

    ## Example

        computation
        |> DB.Ecto.with_handler(MyApp.Repo)
        |> Comp.run!()

        # With transaction options
        computation
        |> DB.Ecto.with_handler(MyApp.Repo, timeout: 15_000)
        |> Comp.run!()

        # Preserve specific state keys on rollback
        computation
        |> DB.Ecto.with_handler(MyApp.Repo,
          preserve_state_on_rollback: [Writer.state_key(:metrics)]
        )
        |> Comp.run!()
    """
    @spec with_handler(Types.computation(), module(), keyword()) :: Types.computation()
    def with_handler(comp, repo, opts \\ []) do
      {preserve_keys, ecto_opts} = Keyword.pop(opts, :preserve_state_on_rollback, [])

      config = %{
        repo: repo,
        ecto_opts: ecto_opts,
        preserve_state_on_rollback: preserve_keys
      }

      comp
      |> Comp.scoped(fn env ->
        previous = Env.get_state(env, @state_key)
        modified = Env.put_state(env, @state_key, config)

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
      |> Comp.with_handler(DB.sig(), &__MODULE__.handle/3)
    end

    @doc """
    Install Ecto handler via catch clause syntax.

        catch
          DB.Ecto -> MyApp.Repo
          DB.Ecto -> {MyApp.Repo, timeout: 5000}
          DB.Ecto -> {MyApp.Repo, preserve_state_on_rollback: [key]}
    """
    @impl Skuld.Comp.IInstall
    def __handle__(comp, {repo, opts}) when is_atom(repo) and is_list(opts) do
      with_handler(comp, repo, opts)
    end

    def __handle__(comp, repo) when is_atom(repo) do
      with_handler(comp, repo, [])
    end

    #############################################################################
    ## IHandle — Write Operations
    #############################################################################

    @impl Skuld.Comp.IHandle
    def handle(%DB.Insert{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {changeset, merged_opts} = normalize_input(input, opts)

      case repo.insert(changeset, merged_opts) do
        {:ok, struct} -> k.(struct, env)
        {:error, changeset} -> {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandle
    def handle(%DB.Update{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {changeset, merged_opts} = normalize_input(input, opts)

      case repo.update(changeset, merged_opts) do
        {:ok, struct} -> k.(struct, env)
        {:error, changeset} -> {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandle
    def handle(%DB.Upsert{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {changeset, merged_opts} = normalize_input(input, opts)

      case repo.insert_or_update(changeset, merged_opts) do
        {:ok, struct} -> k.(struct, env)
        {:error, changeset} -> {%ThrowResult{error: {:invalid_changeset, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandle
    def handle(%DB.Delete{input: input, opts: opts}, env, k) do
      repo = get_repo!(env)
      {struct_or_changeset, merged_opts} = normalize_delete_input(input, opts)

      case repo.delete(struct_or_changeset, merged_opts) do
        {:ok, struct} -> k.({:ok, struct}, env)
        {:error, changeset} -> {%ThrowResult{error: {:delete_failed, changeset}}, env}
      end
    end

    @impl Skuld.Comp.IHandle
    def handle(%DB.InsertAll{schema: schema, entries: entries, opts: opts}, env, k) do
      repo = get_repo!(env)

      case validate_and_convert_entries(schema, entries, :insert) do
        {:ok, maps} ->
          result = repo.insert_all(schema, maps, opts)
          k.(result, env)

        {:error, reason} ->
          {%ThrowResult{error: reason}, env}
      end
    end

    @impl Skuld.Comp.IHandle
    def handle(
          %DB.UpdateAll{schema: _schema, entries: entries, opts: opts},
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

    @impl Skuld.Comp.IHandle
    def handle(
          %DB.UpsertAll{schema: schema, entries: entries, opts: opts},
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

    @impl Skuld.Comp.IHandle
    def handle(
          %DB.DeleteAll{schema: _schema, entries: entries, opts: opts},
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
    ## IHandle — Transaction Operations
    #############################################################################

    @impl Skuld.Comp.IHandle
    def handle(%DB.Transact{comp: inner_comp}, env, k) do
      config = get_config!(env)
      handle_transact(inner_comp, config, env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle(%DB.Rollback{}, _env, _k) do
      raise ArgumentError, """
      DB.rollback/1 called outside of a transaction.

      rollback/1 must be called within a DB.transact/1 block:

          comp do
            result <- DB.transact(comp do
              # ... do work ...
              _ <- DB.rollback(:some_reason)
            end)
            return(result)
          end
      """
    end

    #############################################################################
    ## Private Helpers — Write Operations
    #############################################################################

    defp get_repo!(env) do
      case Env.get_state(env, @state_key) do
        nil ->
          raise "DB.Ecto handler not installed. Use DB.Ecto.with_handler/2"

        %{repo: repo} ->
          repo
      end
    end

    defp get_config!(env) do
      case Env.get_state(env, @state_key) do
        nil ->
          raise "DB.Ecto handler not installed. Use DB.Ecto.with_handler/2"

        %{} = config ->
          config
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

    #############################################################################
    ## Private Helpers — Transaction Operations
    #############################################################################

    # Handle the transact operation - run inner comp in Ecto transaction
    defp handle_transact(inner_comp, config, env, k) do
      %{repo: repo, ecto_opts: ecto_opts} = config

      result =
        repo.transaction(
          fn -> execute_in_transaction(inner_comp, config, env) end,
          ecto_opts
        )

      handle_result(result, config, env, k)
    end

    # Marker struct for explicit rollback (not a sentinel - just a result value
    # that execute_in_transaction detects to trigger repo.rollback)
    defmodule RollbackMarker do
      @moduledoc false
      defstruct [:reason]
    end

    # Run the computation inside the Ecto transaction
    defp execute_in_transaction(comp, config, env) do
      %{repo: repo} = config

      # Install a handler that overrides rollback and nested transact,
      # while delegating all other operations (writes) to the main handler.
      wrapped =
        comp
        |> Comp.with_handler(DB.sig(), fn
          %DB.Rollback{reason: reason}, e, _inner_k ->
            # Return a marker instead of calling repo.rollback directly,
            # because call_handler's catch clause would intercept the throw.
            # execute_in_transaction will detect this marker and call repo.rollback.
            {%RollbackMarker{reason: reason}, e}

          %DB.Transact{comp: nested_comp}, e, nested_k ->
            # Nested transact creates a savepoint via Ecto.
            # Nested transactions inherit the parent's config.
            handle_transact(nested_comp, config, e, nested_k)

          op, e, inner_k ->
            # All other operations (writes) - delegate to main handler
            handle(op, e, inner_k)
        end)

      # Run the computation with identity continuation
      {result, final_env} = Comp.call(wrapped, env, &Comp.identity_k/2)

      # Check what happened
      case result do
        %RollbackMarker{reason: reason} ->
          # Explicit rollback - exit the transaction
          repo.rollback({:rollback, reason, final_env})

        result ->
          if ISentinel.sentinel?(result) do
            # Sentinel (Throw, Suspend, etc.) - rollback and propagate
            repo.rollback({:sentinel, result, final_env})
          else
            {:ok, result, final_env}
          end
      end
    end

    # Restore env state to pre-transaction values on rollback, keeping only
    # the preserve_state_on_rollback keys from the post-transaction env.
    defp restore_state_on_rollback(pre_tx_env, final_env, preserve_keys) do
      preserved_state =
        Enum.reduce(preserve_keys, %{}, fn key, acc ->
          case Map.fetch(final_env.state, key) do
            {:ok, val} -> Map.put(acc, key, val)
            :error -> acc
          end
        end)

      %{pre_tx_env | state: Map.merge(pre_tx_env.state, preserved_state)}
    end

    # Handle the transaction result
    defp handle_result({:ok, {:ok, value, final_env}}, _config, _env, k) do
      # Transaction committed successfully — use post-transaction env as-is
      k.(value, final_env)
    end

    defp handle_result(
           {:error, {:sentinel, sentinel, final_env}},
           config,
           env,
           _k
         ) do
      # Sentinel (Throw, Suspend, etc.) - transaction rolled back.
      # Restore pre-transaction env state (except preserved keys).
      restored_env =
        restore_state_on_rollback(env, final_env, config.preserve_state_on_rollback)

      {sentinel, restored_env}
    end

    defp handle_result(
           {:error, {:rollback, reason, final_env}},
           config,
           env,
           k
         ) do
      # Explicit rollback - restore pre-transaction env state (except preserved keys).
      restored_env =
        restore_state_on_rollback(env, final_env, config.preserve_state_on_rollback)

      k.({:rolled_back, reason}, restored_env)
    end
  end
end
