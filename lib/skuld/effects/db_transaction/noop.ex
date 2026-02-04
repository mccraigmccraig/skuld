# No-op transaction handler for the DBTransaction effect.
#
# Does not actually create a transaction - useful for testing or when
# you want to use code that expects a transaction handler but don't
# need actual transaction semantics.
#
# ## Behavior
#
# For `transact(comp)`:
# - Normal completion → returns result (no actual commit)
# - Throw/Suspend → propagates normally (no actual rollback)
# - Explicit `rollback(reason)` → returns `{:rolled_back, reason}` (no actual rollback)
#
# ## Example
#
#     alias Skuld.Comp
#     alias Skuld.Effects.DBTransaction
#     alias Skuld.Effects.DBTransaction.Noop, as: NoopTx
#
#     # In tests, use Noop instead of Ecto
#     comp do
#       result <- DBTransaction.transact(comp do
#         _ <- do_something()
#         return(:ok)
#       end)
#       return(result)
#     end
#     |> NoopTx.with_handler()
#     |> Comp.run!()
defmodule Skuld.Effects.DBTransaction.Noop do
  @moduledoc false

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  alias Skuld.Comp
  alias Skuld.Comp.ISentinel
  alias Skuld.Effects.DBTransaction

  @doc """
  Install a no-op transaction handler.

  Handles `transact` operations by simply running the inner computation
  without any actual transaction wrapping. The `rollback/1` operation
  returns `{:rolled_back, reason}` without actually rolling back anything.

  ## Example

      comp do
        result <- DBTransaction.transact(comp do
          _ <- DBTransaction.rollback(:test_reason)
          return(:never_reached)
        end)
        return(result)
      end
      |> DBTransaction.Noop.with_handler()
      |> Comp.run!()
      #=> {:rolled_back, :test_reason}
  """
  @spec with_handler(Comp.Types.computation()) :: Comp.Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, DBTransaction.sig(), &__MODULE__.handle/3)
  end

  @doc """
  Install Noop handler via catch clause syntax.

      catch
        DBTransaction.Noop -> nil
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, _config), do: with_handler(comp)

  @impl Skuld.Comp.IHandle
  def handle(%DBTransaction.Transact{comp: inner_comp}, env, k) do
    handle_transact(inner_comp, env, k)
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

  # Handle the transact operation - run inner comp without actual transaction
  defp handle_transact(inner_comp, env, k) do
    # Handler for explicit rollback (inside transact block)
    rollback_handler = fn %DBTransaction.Rollback{reason: reason}, e, _inner_k ->
      # Return {:rolled_back, reason} - don't call continuation
      {{:rolled_back, reason}, e}
    end

    # Handler for nested transact (just run it)
    transact_handler = fn %DBTransaction.Transact{comp: nested_comp}, e, nested_k ->
      handle_transact(nested_comp, e, nested_k)
    end

    # Install handlers for both rollback and nested transact
    wrapped =
      inner_comp
      |> Comp.with_handler(DBTransaction.sig(), fn
        %DBTransaction.Rollback{} = op, e, inner_k ->
          rollback_handler.(op, e, inner_k)

        %DBTransaction.Transact{} = op, e, inner_k ->
          transact_handler.(op, e, inner_k)
      end)

    # Run the computation
    {result, final_env} = Comp.call(wrapped, env, &Comp.identity_k/2)

    # Handle sentinels - propagate them without calling k
    if ISentinel.sentinel?(result) do
      # Sentinel (Throw, Suspend, etc.) - propagate without calling k
      {result, final_env}
    else
      # Normal result - pass to continuation
      k.(result, final_env)
    end
  end
end
