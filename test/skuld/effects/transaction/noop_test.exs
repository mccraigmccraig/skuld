defmodule Skuld.Effects.Transaction.NoopTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.EventAccumulator
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Transaction
  alias Skuld.Effects.Writer

  describe "transact" do
    test "normal completion returns result" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                return(:ok)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert :ok == Comp.run!(computation)
    end

    test "computation result is passed through" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                x <- return(21)
                return(x * 2)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert 42 == Comp.run!(computation)
    end

    test "multiple operations in transaction" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                a <- return(:first)
                b <- return(:second)
                return({a, b})
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert {:first, :second} == Comp.run!(computation)
    end

    test "explicit rollback returns {:rolled_back, reason}" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                _ <- Transaction.rollback(:test_reason)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert {:rolled_back, :test_reason} == Comp.run!(computation)
    end

    test "rollback with complex reason" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                _ <- Transaction.rollback({:validation_failed, %{field: :email}})
                return(:never_reached)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert {:rolled_back, {:validation_failed, %{field: :email}}} == Comp.run!(computation)
    end

    test "conditional rollback" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                x = -1

                inner_result <-
                  if x < 0 do
                    Transaction.rollback({:negative, x})
                  else
                    Comp.return(x)
                  end

                return(inner_result)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert {:rolled_back, {:negative, -1}} == Comp.run!(computation)
    end

    test "conditional no-rollback" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                x = 42

                inner_result <-
                  if x < 0 do
                    Transaction.rollback({:negative, x})
                  else
                    Comp.return(x)
                  end

                return(inner_result)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert 42 == Comp.run!(computation)
    end
  end

  describe "rollback outside transact" do
    test "raises error" do
      computation =
        comp do
          _ <- Transaction.rollback(:outside_transact)
          return(:never_reached)
        end
        |> Transaction.Noop.with_handler()

      assert_raise ArgumentError,
                   ~r/Transaction\.rollback\/1 called outside of a transaction/,
                   fn ->
                     Comp.run!(computation)
                   end
    end
  end

  describe "nested transactions" do
    test "nested transact works" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                outer <- return(:outer_value)

                inner_result <-
                  Transaction.transact(
                    comp do
                      return(:inner_value)
                    end
                  )

                return({outer, inner_result})
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert {:outer_value, :inner_value} == Comp.run!(computation)
    end

    test "inner rollback doesn't affect outer" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                inner_result <-
                  Transaction.transact(
                    comp do
                      _ <- Transaction.rollback(:inner_rollback)
                      return(:never_reached)
                    end
                  )

                return({:outer_ok, inner_result})
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert {:outer_ok, {:rolled_back, :inner_rollback}} == Comp.run!(computation)
    end
  end

  describe "throw propagation" do
    test "throw propagates through noop handler" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                _ <- Throw.throw(:something_went_wrong)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()
        |> Throw.with_handler()

      {result, _env} = Comp.run(computation)
      assert %Comp.Throw{error: :something_went_wrong} = result
    end

    test "throw after some work propagates" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                x <- return(42)
                _ <- Throw.throw({:failed, x})
                return(:never_reached)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()
        |> Throw.with_handler()

      {result, _env} = Comp.run(computation)
      assert %Comp.Throw{error: {:failed, 42}} = result
    end
  end

  describe "transactional state rollback" do
    test "explicit rollback restores env state to pre-transaction values" do
      computation =
        comp do
          _ <- EventAccumulator.emit(:before_tx)

          result <-
            Transaction.transact(
              comp do
                _ <- EventAccumulator.emit(:inside_tx_1)
                _ <- EventAccumulator.emit(:inside_tx_2)
                _ <- Transaction.rollback(:test_reason)
                return(:never_reached)
              end
            )

          _ <- EventAccumulator.emit(:after_rollback)
          return(result)
        end
        |> Transaction.Noop.with_handler()
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {result, events} = Comp.run!(computation)
      assert {:rolled_back, :test_reason} = result
      # Events from inside the rolled-back transaction should be discarded
      assert events == [:before_tx, :after_rollback]
    end

    test "throw rollback restores env state to pre-transaction values" do
      computation =
        comp do
          _ <- EventAccumulator.emit(:before_tx)

          result <-
            Transaction.transact(
              comp do
                _ <- EventAccumulator.emit(:inside_tx)
                _ <- Throw.throw(:something_failed)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()
        |> EventAccumulator.with_handler(output: &{&1, &2})
        |> Throw.with_handler()

      # The throw propagates through EventAccumulator's with_handler scope,
      # which runs the output function via leave_scope, producing {throw, events}.
      # Events from inside the rolled-back transaction should be discarded.
      {result, _env} = Comp.run(computation)
      assert {%Comp.Throw{error: :something_failed}, events} = result
      assert events == [:before_tx]
    end

    test "successful commit preserves env state from transaction" do
      computation =
        comp do
          _ <- EventAccumulator.emit(:before_tx)

          result <-
            Transaction.transact(
              comp do
                _ <- EventAccumulator.emit(:inside_tx)
                return(:ok)
              end
            )

          _ <- EventAccumulator.emit(:after_tx)
          return(result)
        end
        |> Transaction.Noop.with_handler()
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {result, events} = Comp.run!(computation)
      assert :ok = result
      # Events from committed transaction should be preserved
      assert events == [:before_tx, :inside_tx, :after_tx]
    end

    test "preserve_state_on_rollback keeps specified keys on rollback" do
      metrics_key = Writer.state_key(:metrics)

      computation =
        comp do
          _ <- EventAccumulator.emit(:before_tx)
          _ <- Writer.tell(:metrics, :metric_before)

          result <-
            Transaction.transact(
              comp do
                _ <- EventAccumulator.emit(:inside_tx)
                _ <- Writer.tell(:metrics, :metric_inside)
                _ <- Transaction.rollback(:test_reason)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler(preserve_state_on_rollback: [metrics_key])
        |> EventAccumulator.with_handler(output: &{&1, &2})
        |> Writer.with_handler([],
          tag: :metrics,
          output: fn {r, events}, metrics ->
            {r, events, Enum.reverse(metrics)}
          end
        )

      {result, events, metrics} = Comp.run!(computation)
      assert {:rolled_back, :test_reason} = result
      # EventAccumulator events rolled back (not in preserve list)
      assert events == [:before_tx]
      # Metrics preserved (in preserve list)
      assert metrics == [:metric_before, :metric_inside]
    end

    test "nested transaction rollback restores inner state only" do
      computation =
        comp do
          _ <- EventAccumulator.emit(:outer_before)

          result <-
            Transaction.transact(
              comp do
                _ <- EventAccumulator.emit(:outer_inside)

                inner_result <-
                  Transaction.transact(
                    comp do
                      _ <- EventAccumulator.emit(:inner_tx)
                      _ <- Transaction.rollback(:inner_reason)
                      return(:never_reached)
                    end
                  )

                _ <- EventAccumulator.emit(:outer_after_inner)
                return({:outer_ok, inner_result})
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {result, events} = Comp.run!(computation)
      assert {:outer_ok, {:rolled_back, :inner_reason}} = result
      # Inner transaction events discarded, outer preserved
      assert events == [:outer_before, :outer_inside, :outer_after_inner]
    end
  end

  describe "try_transact" do
    test "wraps successful result in {:ok, value}" do
      computation =
        comp do
          result <-
            Transaction.try_transact(
              comp do
                return(42)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert {:ok, 42} == Comp.run!(computation)
    end

    test "passes through {:rolled_back, reason}" do
      computation =
        comp do
          result <-
            Transaction.try_transact(
              comp do
                _ <- Transaction.rollback(:test_reason)
                return(:never_reached)
              end
            )

          return(result)
        end
        |> Transaction.Noop.with_handler()

      assert {:rolled_back, :test_reason} == Comp.run!(computation)
    end
  end

  describe "IInstall" do
    test "installs via catch clause syntax" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                return(:ok)
              end
            )

          return(result)
        catch
          Transaction.Noop -> nil
        end

      assert :ok == Comp.run!(computation)
    end

    test "installs via catch clause syntax with opts" do
      computation =
        comp do
          result <-
            Transaction.transact(
              comp do
                return(:ok)
              end
            )

          return(result)
        catch
          Transaction.Noop -> [preserve_state_on_rollback: []]
        end

      assert :ok == Comp.run!(computation)
    end
  end
end
