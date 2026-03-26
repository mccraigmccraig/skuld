# Ecto transaction handler for the Transaction effect.
#
# Wraps computations in real database transactions via an Ecto Repo,
# with env state rollback on rollback/sentinel and savepoints for
# nested transactions.
#
# ## Usage
#
#     computation
#     |> Transaction.Ecto.with_handler(MyApp.Repo)
#     |> Comp.run!()
#
# ## Options
#
# All options except `:preserve_state_on_rollback` are passed through to
# `Repo.transaction/2` (e.g. `:timeout`, `:isolation`).
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Transaction.Ecto do
    @moduledoc false

    @behaviour Skuld.Comp.IHandle
    @behaviour Skuld.Comp.IInstall

    alias Skuld.Comp
    alias Skuld.Comp.Env
    alias Skuld.Comp.ISentinel
    alias Skuld.Comp.Types
    alias Skuld.Effects.Transaction

    @state_key {__MODULE__, :config}

    #############################################################################
    ## Handler Installation
    #############################################################################

    @doc """
    Install a scoped Transaction Ecto handler for a computation.

    Handles `transact` and `rollback` operations using real Ecto transactions.

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
        |> Transaction.Ecto.with_handler(MyApp.Repo)
        |> Comp.run!()

        # With transaction options
        computation
        |> Transaction.Ecto.with_handler(MyApp.Repo, timeout: 15_000)
        |> Comp.run!()

        # Preserve specific state keys on rollback
        computation
        |> Transaction.Ecto.with_handler(MyApp.Repo,
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
      |> Comp.with_handler(Transaction.sig(), &__MODULE__.handle/3)
    end

    @doc """
    Install Ecto handler via catch clause syntax.

        catch
          Transaction.Ecto -> MyApp.Repo
          Transaction.Ecto -> {MyApp.Repo, timeout: 5000}
          Transaction.Ecto -> {MyApp.Repo, preserve_state_on_rollback: [key]}
    """
    @impl Skuld.Comp.IInstall
    def __handle__(comp, {repo, opts}) when is_atom(repo) and is_list(opts) do
      with_handler(comp, repo, opts)
    end

    def __handle__(comp, repo) when is_atom(repo) do
      with_handler(comp, repo, [])
    end

    #############################################################################
    ## IHandle
    #############################################################################

    @transact_op Transaction.transact_op()
    @rollback_op Transaction.rollback_op()

    @impl Skuld.Comp.IHandle
    def handle({@transact_op, inner_comp}, env, k) do
      config = get_config!(env)
      handle_transact(inner_comp, config, env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle({@rollback_op, _reason}, _env, _k) do
      raise ArgumentError, """
      Transaction.rollback/1 called outside of a transaction.

      rollback/1 must be called within a Transaction.transact/1 block:

          comp do
            result <- Transaction.transact(comp do
              # ... do work ...
              _ <- Transaction.rollback(:some_reason)
            end)
            return(result)
          end
      """
    end

    # Catch-all for unknown ops
    def handle(op, _env, _k) do
      raise ArgumentError,
            "Transaction.Ecto handler received an unknown operation: #{inspect(op)}"
    end

    #############################################################################
    ## Private Helpers
    #############################################################################

    defp get_config!(env) do
      Env.get_state!(env, @state_key)
    end

    # Marker struct for explicit rollback (not a sentinel — just a result value
    # that execute_in_transaction detects to trigger repo.rollback)
    defmodule RollbackMarker do
      @moduledoc false
      defstruct [:reason]
    end

    # Handle the transact operation — run inner comp in Ecto transaction
    defp handle_transact(inner_comp, config, env, k) do
      %{repo: repo, ecto_opts: ecto_opts} = config

      result =
        repo.transaction(
          fn -> execute_in_transaction(inner_comp, config, env) end,
          ecto_opts
        )

      handle_result(result, config, env, k)
    end

    # Run the computation inside the Ecto transaction
    defp execute_in_transaction(comp, config, env) do
      %{repo: repo} = config

      # Install a handler that overrides rollback and nested transact
      wrapped =
        comp
        |> Comp.with_handler(Transaction.sig(), fn
          {@rollback_op, reason}, e, _inner_k ->
            # Return a marker instead of calling repo.rollback directly,
            # because call_handler's catch clause would intercept the throw.
            # execute_in_transaction will detect this marker and call repo.rollback.
            {%RollbackMarker{reason: reason}, e}

          {@transact_op, nested_comp}, e, nested_k ->
            # Nested transact creates a savepoint via Ecto.
            handle_transact(nested_comp, config, e, nested_k)

          op, e, inner_k ->
            # Unknown operations — delegate to outer handler (shouldn't happen
            # since Transaction only has transact and rollback)
            handle(op, e, inner_k)
        end)

      # Run the computation with identity continuation
      {result, final_env} = Comp.call(wrapped, env, &Comp.identity_k/2)

      # Check what happened
      case result do
        %RollbackMarker{reason: reason} ->
          # Explicit rollback — exit the transaction
          repo.rollback({:rollback, reason, final_env})

        result ->
          if ISentinel.sentinel?(result) do
            # Sentinel (Throw, Suspend, etc.) — rollback and propagate
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
      # Sentinel (Throw, Suspend, etc.) — transaction rolled back.
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
      # Explicit rollback — restore pre-transaction env state (except preserved keys).
      restored_env =
        restore_state_on_rollback(env, final_env, config.preserve_state_on_rollback)

      k.({:rolled_back, reason}, restored_env)
    end
  end
end
