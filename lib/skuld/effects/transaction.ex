defmodule Skuld.Effects.Transaction do
  @moduledoc """
  Transaction effect — env state rollback with optional database transactions.

  Provides transactional semantics for computations: on normal completion the
  transaction commits (env state preserved); on explicit rollback or sentinel
  (Throw, Suspend, etc.) the transaction rolls back (env state restored to
  pre-transaction values, with optional preservation of specified keys).

  ## Why a separate effect?

  Transactions are orthogonal to persistence. A computation may need
  transactional env state rollback without any database involvement (e.g.
  rolling back Writer accumulations on error), or it may combine transactions
  with domain-specific persistence Ports.

  ## Operations

      # Wrap a computation in a transaction
      result <- Transaction.transact(comp do
        _ <- do_some_work()
        return(:ok)
      end)

      # Explicitly roll back the current transaction
      _ <- Transaction.rollback(:reason)

  ## Handlers

  Ecto (real database transaction + env state rollback):

      computation
      |> Transaction.Ecto.with_handler(MyApp.Repo)
      |> Comp.run!()

  Noop (env state rollback only, no database):

      computation
      |> Transaction.Noop.with_handler()
      |> Comp.run!()

  ## Rollback Semantics

  On rollback (explicit or sentinel), `env.state` is restored to
  pre-transaction values. Use `:preserve_state_on_rollback` to opt
  specific state keys out of rollback (e.g. metrics, error counters).

  ## Nested Transactions

  Nested `transact` calls create savepoints (Ecto handler) or
  independent rollback scopes (Noop handler):

      comp do
        result <- Transaction.transact(comp do
          _ <- do_outer_work()

          inner <- Transaction.transact(comp do
            _ <- do_inner_work()
            return(:inner_done)
          end)

          return({:outer_done, inner})
        end)
        return(result)
      end
  """

  use Skuld.Comp.DefOp

  alias Skuld.Comp.Types

  #############################################################################
  ## Operations
  #############################################################################

  def_op transact(comp)
  def_op rollback(reason)

  # Op atom aliases for handler pattern matching
  @transact_op @__transact_op__
  @rollback_op @__rollback_op__

  @doc false
  def transact_op, do: @transact_op

  @doc false
  def rollback_op, do: @rollback_op

  #############################################################################
  ## Derived Operations
  #############################################################################

  @doc """
  Run a computation in a transaction, returning `{:ok, result}` on commit
  or `{:rolled_back, reason}` on rollback.

  This is a convenience for pattern matching on the transaction outcome
  without needing to know whether the result is a normal value or a
  rollback tuple.

  ## Example

      case Transaction.try_transact(inner_comp) do
        {:ok, value} -> handle_success(value)
        {:rolled_back, reason} -> handle_rollback(reason)
      end
  """
  @spec try_transact(Types.computation()) :: Types.computation()
  def try_transact(comp) do
    Skuld.Comp.map(transact(comp), fn
      {:rolled_back, _reason} = rolled_back -> rolled_back
      value -> {:ok, value}
    end)
  end
end
