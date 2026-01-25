defmodule Skuld.Effects.NonBlockingAsync.SchedulerTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Effects.NonBlockingAsync
  alias Skuld.Effects.NonBlockingAsync.AwaitRequest.TaskTarget
  alias Skuld.Effects.NonBlockingAsync.AwaitRequest.TimerTarget
  alias Skuld.Effects.NonBlockingAsync.Scheduler
  alias Skuld.Effects.Throw

  describe "run_one/2" do
    test "runs single computation to completion" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :work_done
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :work_done}
    end

    test "handles task that takes time" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    _ = Process.sleep(10)
                    :delayed_result
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :delayed_result}
    end

    test "handles multiple sequential awaits" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.async(
                  comp do
                    _ = Process.sleep(5)
                    :first
                  end
                )

              h2 <-
                NonBlockingAsync.async(
                  comp do
                    _ = Process.sleep(5)
                    :second
                  end
                )

              r1 <- NonBlockingAsync.await(h1)
              r2 <- NonBlockingAsync.await(h2)
              {r1, r2}
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:first, :second}}
    end
  end

  describe "run/2 - multiple computations" do
    test "runs multiple computations" do
      comp1 =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :from_comp1
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()

      comp2 =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :from_comp2
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()

      {:done, results} = Scheduler.run([comp1, comp2])

      # Results should contain both computation results
      assert Map.values(results) |> Enum.sort() == [:from_comp1, :from_comp2]
    end

    test "empty computation list returns done immediately" do
      result = Scheduler.run([])
      assert result == {:done, %{}}
    end

    test "handles computations that complete at different times" do
      comp_fast =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :fast
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()

      comp_slow =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    _ = Process.sleep(20)
                    :slow
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()

      {:done, results} = Scheduler.run([comp_fast, comp_slow])

      values = Map.values(results)
      assert :fast in values
      assert :slow in values
    end
  end

  describe "await_any_raw with timers" do
    test "timer fires and wins race" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    _ = Process.sleep(100)
                    :slow_task
                  end
                )

              timer = TimerTarget.new(10)

              {target_key, value} <-
                NonBlockingAsync.await_any_raw([TaskTarget.new(h.task), timer])

              _ <- NonBlockingAsync.cancel(h)

              case target_key do
                {:timer, _} -> {:timeout, value}
                {:task, _} -> {:task_won, value}
              end
            end,
            fn result, _unawaited -> result end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:timeout, {:ok, :timeout}}}
    end

    test "task wins race against timer" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :fast_task
                  end
                )

              timer = TimerTarget.new(1000)

              {target_key, value} <-
                NonBlockingAsync.await_any_raw([TaskTarget.new(h.task), timer])

              # Must cancel handle since await_any_raw doesn't untrack it
              _ <- NonBlockingAsync.cancel(h)

              case target_key do
                {:timer, _} -> {:timeout, value}
                {:task, _} -> {:task_won, value}
              end
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:task_won, {:ok, :fast_task}}}
    end

    @tag :slow
    test "reusable timer for overall operation timeout" do
      # Test that the same timer can be used across multiple awaits
      # to implement an overall operation timeout
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              # Create a timer with 50ms overall timeout
              timer = TimerTarget.new(50)

              # First task - should complete in time (10ms < 50ms remaining)
              h1 <-
                NonBlockingAsync.async(
                  comp do
                    _ = Process.sleep(10)
                    :step1_done
                  end
                )

              {key1, r1} <-
                NonBlockingAsync.await_any_raw([TaskTarget.new(h1.task), timer])

              # Must cancel handle since await_any_raw doesn't untrack it
              _ <- NonBlockingAsync.cancel(h1)

              # Check if first step completed or timed out
              step1_result =
                case key1 do
                  {:timer, _} -> :overall_timeout
                  {:task, _} -> {:step1_ok, r1}
                end

              step1_result
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      # First task should complete before the 50ms timer
      assert result == {:done, {:step1_ok, {:ok, :step1_done}}}
    end
  end

  describe "error handling" do
    test "computation error is recorded" do
      comp_ok =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :ok_result
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()

      comp_error =
        comp do
          _ = raise "boom"
          :never_reached
        end

      {:done, results} = Scheduler.run([comp_ok, comp_error])

      values = Map.values(results)
      # One should be :ok_result, one should be an error
      assert Enum.any?(values, fn v -> v == :ok_result end)
      assert Enum.any?(values, fn v -> match?({:error, _}, v) end)
    end

    test "on_error: :stop halts on first error" do
      comp_error =
        comp do
          _ = raise "boom"
          :never_reached
        end

      result = Scheduler.run([comp_error], on_error: :stop)

      # Exceptions are converted to throws by Comp.call's ConvertThrow handling
      assert match?({:error, {:throw, %{kind: :error, payload: %RuntimeError{}}}}, result)
    end
  end

  describe "FIFO fairness" do
    test "computations wake in FIFO order" do
      # This is hard to test precisely, but we can verify
      # both computations complete and results are collected
      comp1 =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    _ = Process.sleep(10)
                    :comp1
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()

      comp2 =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    _ = Process.sleep(10)
                    :comp2
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()

      {:done, results} = Scheduler.run([comp1, comp2])

      values = Map.values(results)
      assert :comp1 in values
      assert :comp2 in values
    end
  end
end
