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
# - Throw/Suspend → propagates normally (no actual rollback)
# - Explicit `rollback(reason)` → returns `{:rolled_back, reason}` (no actual rollback)
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
  alias Skuld.Comp.ISentinel
  alias Skuld.Effects.DB

  @doc """
  Install a no-op DB handler.

  Handles `transact` operations by simply running the inner computation
  without any actual transaction wrapping. The `rollback/1` operation
  returns `{:rolled_back, reason}` without actually rolling back anything.

  Write operations (insert, update, etc.) will raise - use `DB.Test`
  for testing writes.

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
  @spec with_handler(Comp.Types.computation()) :: Comp.Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, DB.sig(), &__MODULE__.handle/3)
  end

  @doc """
  Install Noop handler via catch clause syntax.

      catch
        DB.Noop -> nil
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, _config), do: with_handler(comp)

  #############################################################################
  ## Transaction Operations
  #############################################################################

  @impl Skuld.Comp.IHandle
  def handle(%DB.Transact{comp: inner_comp}, env, k) do
    handle_transact(inner_comp, env, k)
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

  # Handle the transact operation - run inner comp without actual transaction
  defp handle_transact(inner_comp, env, k) do
    # Handler for explicit rollback (inside transact block)
    rollback_handler = fn %DB.Rollback{reason: reason}, e, _inner_k ->
      # Return {:rolled_back, reason} - don't call continuation
      {{:rolled_back, reason}, e}
    end

    # Handler for nested transact (just run it)
    transact_handler = fn %DB.Transact{comp: nested_comp}, e, nested_k ->
      handle_transact(nested_comp, e, nested_k)
    end

    # Install handlers for both rollback and nested transact
    wrapped =
      inner_comp
      |> Comp.with_handler(DB.sig(), fn
        %DB.Rollback{} = op, e, inner_k ->
          rollback_handler.(op, e, inner_k)

        %DB.Transact{} = op, e, inner_k ->
          transact_handler.(op, e, inner_k)

        op, e, inner_k ->
          # Delegate to the outer handler for non-transaction operations
          handle(op, e, inner_k)
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
