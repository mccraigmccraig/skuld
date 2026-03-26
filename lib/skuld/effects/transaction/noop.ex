# No-op transaction handler for the Transaction effect.
#
# Provides env state rollback semantics without any actual database transaction.
# Useful for testing transactional logic or when you need env state rollback
# but have no database involvement.
#
# ## Behavior
#
# For `transact(comp)`:
# - Normal completion -> returns result, env state preserved
# - Throw/Suspend -> propagates, env state restored to pre-transaction values
# - Explicit `rollback(reason)` -> returns `{:rolled_back, reason}`, env state restored
#
# ## Example
#
#     alias Skuld.Comp
#     alias Skuld.Effects.Transaction
#
#     comp do
#       result <- Transaction.transact(comp do
#         _ <- do_something()
#         return(:ok)
#       end)
#       return(result)
#     end
#     |> Transaction.Noop.with_handler()
#     |> Comp.run!()
defmodule Skuld.Effects.Transaction.Noop do
  @moduledoc false

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.ISentinel
  alias Skuld.Comp.Types
  alias Skuld.Effects.Transaction

  @state_key {__MODULE__, :config}

  @doc """
  Install a no-op Transaction handler.

  Handles `transact` operations by running the inner computation without any
  actual transaction wrapping. Provides env state rollback on rollback/sentinel,
  matching `Transaction.Ecto` semantics.

  ## Options

    * `:preserve_state_on_rollback` - list of `env.state` keys whose values
      should be kept from the post-transaction env even when the transaction
      rolls back. See `Transaction.Ecto.with_handler/3` for details.

  ## Example

      comp do
        result <- Transaction.transact(comp do
          _ <- Transaction.rollback(:test_reason)
          return(:never_reached)
        end)
        return(result)
      end
      |> Transaction.Noop.with_handler()
      |> Comp.run!()
      #=> {:rolled_back, :test_reason}
  """
  @spec with_handler(Types.computation(), keyword()) :: Types.computation()
  def with_handler(comp, opts \\ []) do
    preserve_keys = Keyword.get(opts, :preserve_state_on_rollback, [])

    config = %{
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
  Install Noop handler via catch clause syntax.

      catch
        Transaction.Noop -> nil
        Transaction.Noop -> [preserve_state_on_rollback: [key]]
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, nil), do: with_handler(comp)
  def __handle__(comp, opts) when is_list(opts), do: with_handler(comp, opts)

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
          "Transaction.Noop handler received an unknown operation: #{inspect(op)}"
  end

  #############################################################################
  ## Private Helpers
  #############################################################################

  defp get_config!(env) do
    case Env.get_state(env, @state_key) do
      nil ->
        # Fallback for backwards compatibility if handler installed without config
        %{preserve_state_on_rollback: []}

      %{} = config ->
        config
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

  # Handle the transact operation — run inner comp without actual transaction
  defp handle_transact(inner_comp, config, env, k) do
    # Install handlers for rollback and nested transact
    wrapped =
      inner_comp
      |> Comp.with_handler(Transaction.sig(), fn
        {@rollback_op, reason}, e, _inner_k ->
          # Return {:rolled_back, reason} — don't call continuation
          {{:rolled_back, reason}, e}

        {@transact_op, nested_comp}, e, nested_k ->
          # Nested transact inherits the parent's config
          handle_transact(nested_comp, config, e, nested_k)

        op, e, inner_k ->
          # Unknown operations — delegate to outer handler
          handle(op, e, inner_k)
      end)

    # Run the computation
    {result, final_env} = Comp.call(wrapped, env, &Comp.identity_k/2)

    preserve_keys = config.preserve_state_on_rollback

    cond do
      ISentinel.sentinel?(result) ->
        # Sentinel (Throw, Suspend, etc.) — restore pre-transaction env state
        restored_env = restore_state_on_rollback(env, final_env, preserve_keys)
        {result, restored_env}

      match?({:rolled_back, _}, result) ->
        # Explicit rollback — restore pre-transaction env state
        restored_env = restore_state_on_rollback(env, final_env, preserve_keys)
        k.(result, restored_env)

      true ->
        # Normal result — pass through with post-transaction env
        k.(result, final_env)
    end
  end
end
