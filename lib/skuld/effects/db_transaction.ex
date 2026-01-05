defmodule Skuld.Effects.DBTransaction do
  @moduledoc """
  Effect for database transactions with automatic commit/rollback semantics.

  ## Behavior

  - **Normal completion**: Transaction commits
  - **Throw**: Transaction rolls back, throw propagates
  - **Suspend**: Transaction rolls back, suspend propagates
  - **Explicit rollback**: Transaction rolls back, returns `{:rolled_back, reason}`

  ## Operations

  - `rollback(reason)` - Explicitly roll back the transaction

  ## Handlers

  - `DBTransaction.Ecto.with_handler/3` - Ecto-based transactions
  - `DBTransaction.Noop.with_handler/1` - No-op for testing

  ## Example

      alias Skuld.Effects.{DBTransaction, State}
      alias Skuld.Effects.DBTransaction.Ecto, as: EctoTx

      comp do
        user <- create_user(attrs)
        
        if invalid?(user) do
          _ <- DBTransaction.rollback({:invalid_user, user})
        end
        
        return(user)
      end
      |> EctoTx.with_handler(MyApp.Repo)
      |> Comp.run!()

  ## Rollback on Throw

      comp do
        _ <- Throw.throw(:something_went_wrong)
        return(:never_reached)
      end
      |> EctoTx.with_handler(MyApp.Repo)
      |> Throw.with_handler()
      |> Comp.run!()
      # Transaction is rolled back, returns the throw error
  """

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Rollback, [:reason])

  #############################################################################
  ## Effect Operations
  #############################################################################

  @doc """
  Explicitly roll back the transaction.

  Returns `{:rolled_back, reason}` after the transaction is rolled back.

  ## Example

      comp do
        user <- create_user(attrs)
        
        if should_abort?(user) do
          _ <- DBTransaction.rollback({:aborted, user.id})
        end
        
        return(user)
      end
  """
  @spec rollback(term()) :: Types.computation()
  def rollback(reason) do
    Comp.effect(@sig, %Rollback{reason: reason})
  end

  @doc """
  Get the effect signature for handler installation.
  """
  def sig, do: @sig
end
