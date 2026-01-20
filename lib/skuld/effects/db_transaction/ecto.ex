if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.DBTransaction.Ecto do
    @moduledoc """
    Ecto-based transaction handler for the DBTransaction effect.

    Handles `transact` operations by wrapping computations in `Repo.transaction/2`.
    On normal completion, the transaction commits. On throw, suspend, or explicit
    rollback, the transaction rolls back.

    ## Example

        alias Skuld.Comp
        alias Skuld.Effects.DBTransaction
        alias Skuld.Effects.DBTransaction.Ecto, as: EctoTx

        comp do
          result <- DBTransaction.transact(comp do
            user <- insert_user(attrs)
            order <- insert_order(user, order_attrs)
            return({user, order})
          end)
          return(result)
        end
        |> EctoTx.with_handler(MyApp.Repo)
        |> Comp.run!()

    ## With Explicit Rollback

        comp do
          result <- DBTransaction.transact(comp do
            user <- insert_user(attrs)

            if invalid?(user) do
              _ <- DBTransaction.rollback({:invalid, user})
            end

            return(user)
          end)
          return(result)
        end
        |> EctoTx.with_handler(MyApp.Repo)
        |> Comp.run!()
        #=> {:rolled_back, {:invalid, user}}

    ## Options

    Accepts the same options as `Repo.transaction/2`:

    - `:timeout` - The time in milliseconds to wait for the transaction
    - `:isolation` - The transaction isolation level (if supported)
    """

    @behaviour Skuld.Comp.IHandle
    @behaviour Skuld.Comp.IInstall

    alias Skuld.Comp
    alias Skuld.Comp.Env
    alias Skuld.Comp.ISentinel
    alias Skuld.Effects.DBTransaction

    @state_key {DBTransaction, :ecto_config}

    @doc """
    Install an Ecto transaction handler.

    Handles `DBTransaction.transact/1` operations by running the inner
    computation inside `Repo.transaction/2`.

    ## Behavior

    For `transact(comp)`:
    - Normal completion → commits, returns result
    - Throw sentinel → rolls back, propagates throw
    - Suspend sentinel → rolls back, propagates suspend
    - Explicit `rollback(reason)` → rolls back, returns `{:rolled_back, reason}`

    Calling `rollback/1` outside of a `transact` block raises an error.

    ## Example

        comp do
          result <- DBTransaction.transact(comp do
            _ <- insert_record(data)
            return(:ok)
          end)
          return(result)
        end
        |> DBTransaction.Ecto.with_handler(MyApp.Repo)
        |> Comp.run!()
    """
    @spec with_handler(Comp.Types.computation(), module(), keyword()) :: Comp.Types.computation()
    def with_handler(comp, repo, opts \\ []) do
      comp
      |> Comp.scoped(fn env ->
        previous = Env.get_state(env, @state_key)
        modified = Env.put_state(env, @state_key, {repo, opts})

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
      |> Comp.with_handler(DBTransaction.sig(), &__MODULE__.handle/3)
    end

    @doc """
    Install Ecto handler via catch clause syntax.

        catch
          DBTransaction.Ecto -> MyApp.Repo
          DBTransaction.Ecto -> {MyApp.Repo, timeout: 5000}
    """
    @impl Skuld.Comp.IInstall
    def __handle__(comp, {repo, opts}) when is_atom(repo) and is_list(opts) do
      with_handler(comp, repo, opts)
    end

    def __handle__(comp, repo) when is_atom(repo) do
      with_handler(comp, repo, [])
    end

    @impl Skuld.Comp.IHandle
    def handle(%DBTransaction.Transact{comp: inner_comp}, env, k) do
      {repo, opts} = get_config!(env)
      handle_transact(inner_comp, repo, opts, env, k)
    end

    def handle(%DBTransaction.Rollback{}, _env, _k) do
      raise ArgumentError, """
      DBTransaction.rollback/1 called outside of a transaction.

      rollback/1 must be called within a DBTransaction.transact/1 block:

          comp do
            result <- DBTransaction.transact(comp do
              # ... do work ...
              _ <- DBTransaction.rollback(:some_reason)
            end)
            return(result)
          end
      """
    end

    # Get config from env state
    defp get_config!(env) do
      case Env.get_state(env, @state_key) do
        nil ->
          raise "DBTransaction.Ecto handler not installed. Use DBTransaction.Ecto.with_handler/2"

        config ->
          config
      end
    end

    # Handle the transact operation - run inner comp in Ecto transaction
    defp handle_transact(inner_comp, repo, opts, env, k) do
      result =
        repo.transaction(
          fn -> execute_in_transaction(inner_comp, repo, env) end,
          opts
        )

      handle_result(result, env, k)
    end

    # Run the computation inside the Ecto transaction
    defp execute_in_transaction(comp, repo, env) do
      # Handler for explicit rollback operation (inside transaction)
      rollback_handler = fn %DBTransaction.Rollback{reason: reason}, e, _k ->
        repo.rollback({:rollback, reason, e})
      end

      # Handler for nested transact (creates savepoint via Ecto)
      transact_handler = fn %DBTransaction.Transact{comp: nested_comp}, e, nested_k ->
        handle_transact(nested_comp, repo, [], e, nested_k)
      end

      # Install handlers for both rollback and nested transact
      wrapped =
        comp
        |> Comp.with_handler(DBTransaction.sig(), fn
          %DBTransaction.Rollback{} = op, e, inner_k ->
            rollback_handler.(op, e, inner_k)

          %DBTransaction.Transact{} = op, e, inner_k ->
            transact_handler.(op, e, inner_k)
        end)

      # Run the computation with identity continuation
      {result, final_env} = Comp.call(wrapped, env, &Comp.identity_k/2)

      # Check for sentinels that should cause rollback
      if ISentinel.sentinel?(result) do
        # Sentinel (Throw, Suspend, etc.) - rollback and propagate
        repo.rollback({:sentinel, result, final_env})
      else
        {:ok, result, final_env}
      end
    end

    # Handle the transaction result
    defp handle_result({:ok, {:ok, value, final_env}}, _env, k) do
      # Transaction committed successfully
      k.(value, final_env)
    end

    defp handle_result({:error, {:sentinel, sentinel, final_env}}, _env, _k) do
      # Sentinel (Throw, Suspend, etc.) - transaction rolled back, propagate
      {sentinel, final_env}
    end

    defp handle_result({:error, {:rollback, reason, final_env}}, _env, k) do
      # Explicit rollback - return {:rolled_back, reason}
      k.({:rolled_back, reason}, final_env)
    end
  end
end
