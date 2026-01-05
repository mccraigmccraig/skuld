defmodule Skuld.Effects.DBTransaction.Noop do
  @moduledoc """
  No-op transaction handler for the DBTransaction effect.

  Does not actually create a transaction - useful for testing or when
  you want to use code that expects a transaction handler but don't
  need actual transaction semantics.

  ## Behavior

  - Normal completion → returns result (no actual commit)
  - Throw/Suspend → propagates normally (no actual rollback)
  - Explicit `rollback(reason)` → returns `{:rolled_back, reason}` (no actual rollback)

  ## Example

      alias Skuld.Effects.DBTransaction
      alias Skuld.Effects.DBTransaction.Noop, as: NoopTx

      # In tests, use Noop instead of Ecto
      comp do
        _ <- do_something()
        return(:ok)
      end
      |> NoopTx.with_handler()
      |> Comp.run!()
  """

  alias Skuld.Comp
  alias Skuld.Effects.DBTransaction

  @doc """
  Install a no-op transaction handler.

  The computation runs normally without any transaction wrapping.
  The `rollback/1` operation returns `{:rolled_back, reason}` without
  actually rolling back anything.

  ## Example

      comp do
        _ <- DBTransaction.rollback(:test_reason)
        return(:never_reached)
      end
      |> DBTransaction.Noop.with_handler()
      |> Comp.run!()
      #=> {:rolled_back, :test_reason}
  """
  @spec with_handler(Comp.Types.computation()) :: Comp.Types.computation()
  def with_handler(comp) do
    # Handler for rollback - returns directly, aborting the computation
    # By not calling k, the computation stops and returns {:rolled_back, reason}
    rollback_handler = fn %DBTransaction.Rollback{reason: reason}, env, _k ->
      {{:rolled_back, reason}, env}
    end

    Comp.with_handler(comp, DBTransaction.sig(), rollback_handler)
  end
end
