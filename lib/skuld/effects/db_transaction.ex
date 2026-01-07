defmodule Skuld.Effects.DBTransaction do
  @moduledoc """
  Effect for database transactions with automatic commit/rollback semantics.

  ## Operations

  - `transact(comp)` - Run a computation inside a transaction
  - `rollback(reason)` - Explicitly roll back the current transaction

  ## Behavior

  Within a `transact` block:

  - **Normal completion**: Transaction commits
  - **Throw**: Transaction rolls back, throw propagates
  - **Suspend**: Transaction rolls back, suspend propagates
  - **Explicit rollback**: Transaction rolls back, returns `{:rolled_back, reason}`

  ## Handlers

  - `DBTransaction.Ecto.with_handler/2,3` - Ecto-based transactions
  - `DBTransaction.Noop.with_handler/1` - No-op for testing

  ## Example

      alias Skuld.Comp
      alias Skuld.Effects.DBTransaction
      alias Skuld.Effects.DBTransaction.Ecto, as: EctoTx

      comp do
        result <- DBTransaction.transact(comp do
          user <- create_user(attrs)

          if invalid?(user) do
            _ <- DBTransaction.rollback({:invalid_user, user})
          end

          return(user)
        end)

        return(result)
      end
      |> EctoTx.with_handler(MyApp.Repo)
      |> Comp.run!()

  ## Rollback on Throw

      comp do
        result <- DBTransaction.transact(comp do
          _ <- Throw.throw(:something_went_wrong)
          return(:never_reached)
        end)
        return(result)
      end
      |> EctoTx.with_handler(MyApp.Repo)
      |> Throw.with_handler()
      |> Comp.run!()
      # Transaction is rolled back, returns the throw error

  ## Nested Transactions

  Nested `transact` calls create savepoints (if supported by the database):

      comp do
        result <- DBTransaction.transact(comp do
          _ <- insert_parent()

          inner_result <- DBTransaction.transact(comp do
            _ <- insert_child()
            return(:inner_done)
          end)

          return({:outer_done, inner_result})
        end)
        return(result)
      end
      |> EctoTx.with_handler(MyApp.Repo)
      |> Comp.run!()
  """

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Transact, [:comp])
  def_op(Rollback, [:reason])

  #############################################################################
  ## Effect Operations
  #############################################################################

  @doc """
  Run a computation inside a database transaction.

  The inner computation will be executed within a transaction scope.
  On normal completion, the transaction commits. On throw, suspend,
  or explicit rollback, the transaction rolls back.

  ## Parameters

  - `comp` - The computation to run inside the transaction

  ## Returns

  A computation that returns the result of the inner computation,
  or `{:rolled_back, reason}` if explicitly rolled back.

  ## Example

      comp do
        result <- DBTransaction.transact(comp do
          user <- insert_user(attrs)
          order <- insert_order(user, order_attrs)
          return({user, order})
        end)

        # result is {user, order} if successful
        return(result)
      end
      |> DBTransaction.Ecto.with_handler(MyApp.Repo)
      |> Comp.run!()
  """
  @spec transact(Types.computation()) :: Types.computation()
  def transact(comp) do
    Comp.effect(@sig, %Transact{comp: comp})
  end

  @doc """
  Explicitly roll back the current transaction.

  Must be called within a `transact` block. Returns `{:rolled_back, reason}`
  after the transaction is rolled back.

  ## Example

      comp do
        result <- DBTransaction.transact(comp do
          user <- create_user(attrs)

          if should_abort?(user) do
            _ <- DBTransaction.rollback({:aborted, user.id})
          end

          return(user)
        end)

        return(result)
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
