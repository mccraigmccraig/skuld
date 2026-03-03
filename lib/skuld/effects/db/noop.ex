# No-op handler for the DB effect.
#
# Does not actually create a transaction or persist anything - useful for testing
# or when you want to use code that expects a DB handler but don't need actual
# database operations.
#
# ## Behavior
#
# For write operations (insert, update, etc.):
# - Raises an error. Use DB.Test for testing writes.
#
# For `transact(comp)`:
# - Normal completion → returns result (no actual commit)
# - Throw/Suspend → propagates normally, env state restored to pre-transaction values
# - Explicit `rollback(reason)` → returns `{:rolled_back, reason}`, env state restored
#
# ## Example
#
#     alias Skuld.Comp
#     alias Skuld.Effects.DB
#
#     # In tests, use Noop for transaction-only testing
#     comp do
#       result <- DB.transact(comp do
#         _ <- do_something()
#         return(:ok)
#       end)
#       return(result)
#     end
#     |> DB.Noop.with_handler()
#     |> Comp.run!()
defmodule Skuld.Effects.DB.Noop do
  @moduledoc false

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.ISentinel
  alias Skuld.Effects.DB

  @state_key {DB, :noop_config}

  @doc """
  Install a no-op DB handler.

  Handles `transact` operations by simply running the inner computation
  without any actual transaction wrapping. The `rollback/1` operation
  returns `{:rolled_back, reason}` without actually rolling back anything.

  On rollback or sentinel, env state is restored to pre-transaction values
  (matching DB.Ecto semantics).

  Write operations (insert, update, etc.) will raise - use `DB.Test`
  for testing writes.

  ## Options

    * `:preserve_state_on_rollback` - list of `env.state` keys whose values
      should be kept from the post-transaction env even when the transaction
      rolls back. See `DB.Ecto.with_handler/3` for details.

  ## Example

      comp do
        result <- DB.transact(comp do
          _ <- DB.rollback(:test_reason)
          return(:never_reached)
        end)
        return(result)
      end
      |> DB.Noop.with_handler()
      |> Comp.run!()
      #=> {:rolled_back, :test_reason}
  """
  @spec with_handler(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
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
    |> Comp.with_handler(DB.sig(), &__MODULE__.handle/3)
  end

  @doc """
  Install Noop handler via catch clause syntax.

      catch
        DB.Noop -> nil
        DB.Noop -> [preserve_state_on_rollback: [key]]
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, nil), do: with_handler(comp)
  def __handle__(comp, opts) when is_list(opts), do: with_handler(comp, opts)

  #############################################################################
  ## Transaction Operations
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
  ## Write Operations — pass through (raise if not handled by inner handler)
  #############################################################################

  @impl Skuld.Comp.IHandle
  def handle(op, _env, _k) do
    raise ArgumentError, """
    DB.Noop handler received a write operation: #{inspect(op.__struct__)}

    DB.Noop only handles transaction operations (transact/rollback).
    Use DB.Test.with_handler/2 for testing write operations.
    """
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

  # Handle the transact operation - run inner comp without actual transaction
  defp handle_transact(inner_comp, config, env, k) do
    # Install handlers for rollback and nested transact
    wrapped =
      inner_comp
      |> Comp.with_handler(DB.sig(), fn
        %DB.Rollback{reason: reason}, e, _inner_k ->
          # Return {:rolled_back, reason} - don't call continuation
          {{:rolled_back, reason}, e}

        %DB.Transact{comp: nested_comp}, e, nested_k ->
          # Nested transact inherits the parent's config
          handle_transact(nested_comp, config, e, nested_k)

        op, e, inner_k ->
          # Delegate to the outer handler for non-transaction operations
          handle(op, e, inner_k)
      end)

    # Run the computation
    {result, final_env} = Comp.call(wrapped, env, &Comp.identity_k/2)

    preserve_keys = config.preserve_state_on_rollback

    cond do
      ISentinel.sentinel?(result) ->
        # Sentinel (Throw, Suspend, etc.) - restore pre-transaction env state
        restored_env = restore_state_on_rollback(env, final_env, preserve_keys)
        {result, restored_env}

      match?({:rolled_back, _}, result) ->
        # Explicit rollback - restore pre-transaction env state
        restored_env = restore_state_on_rollback(env, final_env, preserve_keys)
        k.(result, restored_env)

      true ->
        # Normal result - pass through with post-transaction env
        k.(result, final_env)
    end
  end
end
