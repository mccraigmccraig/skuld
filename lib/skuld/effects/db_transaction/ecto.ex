if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.DBTransaction.Ecto do
    @moduledoc """
    Ecto-based transaction handler for the DBTransaction effect.

    Wraps computations in `Repo.transaction/2`. On normal completion,
    the transaction commits. On throw, suspend, or explicit rollback,
    the transaction rolls back.

    ## Example

        alias Skuld.Effects.DBTransaction
        alias Skuld.Effects.DBTransaction.Ecto, as: EctoTx

        comp do
          user <- insert_user(attrs)
          order <- insert_order(user, order_attrs)
          return({user, order})
        end
        |> EctoTx.with_handler(MyApp.Repo)
        |> Comp.run!()

    ## With Explicit Rollback

        comp do
          user <- insert_user(attrs)

          if invalid?(user) do
            _ <- DBTransaction.rollback({:invalid, user})
          end

          return(user)
        end
        |> EctoTx.with_handler(MyApp.Repo)
        |> Comp.run!()
        #=> {:rolled_back, {:invalid, user}}

    ## Options

    Accepts the same options as `Repo.transaction/2`:

    - `:timeout` - The time in milliseconds to wait for the transaction
    - `:isolation` - The transaction isolation level (if supported)
    """

    alias Skuld.Comp
    alias Skuld.Effects.DBTransaction

    @doc """
    Install an Ecto transaction handler.

    The computation runs inside `Repo.transaction/2`.

    ## Behavior

    - Normal completion → commits, returns result
    - Throw sentinel → rolls back, propagates throw
    - Suspend sentinel → rolls back, propagates suspend
    - Explicit `rollback(reason)` → rolls back, returns `{:rolled_back, reason}`

    ## Example

        comp do
          _ <- insert_record(data)
          return(:ok)
        end
        |> DBTransaction.Ecto.with_handler(MyApp.Repo)
        |> Comp.run!()
    """
    @spec with_handler(Comp.Types.computation(), module(), keyword()) :: Comp.Types.computation()
    def with_handler(comp, repo, opts \\ []) do
      fn env, k ->
        result =
          repo.transaction(
            fn -> execute_in_transaction(comp, repo, env) end,
            opts
          )

        handle_result(result, env, k)
      end
    end

    # Run the computation inside the Ecto transaction
    defp execute_in_transaction(comp, repo, env) do
      # Handler for explicit rollback operation
      rollback_handler = fn %DBTransaction.Rollback{reason: reason}, e, _k ->
        repo.rollback({:rollback, reason, e})
      end

      # Install the rollback handler
      wrapped = Comp.with_handler(comp, DBTransaction.sig(), rollback_handler)

      # Run the computation with identity continuation
      {result, final_env} = wrapped.(env, &Comp.identity_k/2)

      # Check for sentinels that should cause rollback
      cond do
        match?(%Skuld.Comp.Throw{}, result) ->
          repo.rollback({:throw, result, final_env})

        match?(%Skuld.Comp.Suspend{}, result) ->
          repo.rollback({:suspend, result, final_env})

        true ->
          {:ok, result, final_env}
      end
    end

    # Handle the transaction result
    defp handle_result({:ok, {:ok, value, final_env}}, _env, k) do
      # Transaction committed successfully
      k.(value, final_env)
    end

    defp handle_result({:error, {:throw, throw_sentinel, final_env}}, _env, _k) do
      # Threw - transaction rolled back, propagate the throw
      {throw_sentinel, final_env}
    end

    defp handle_result({:error, {:suspend, suspend_sentinel, final_env}}, _env, _k) do
      # Suspended - transaction rolled back, propagate the suspend
      {suspend_sentinel, final_env}
    end

    defp handle_result({:error, {:rollback, reason, final_env}}, _env, k) do
      # Explicit rollback - return {:rolled_back, reason}
      k.({:rolled_back, reason}, final_env)
    end
  end
end
