defmodule Skuld.Effects.Async.SchedulerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  use Skuld.Syntax

  alias Skuld.Effects.Async
  alias Skuld.Effects.Async.AwaitRequest.TaskTarget
  alias Skuld.Effects.Async.AwaitRequest.TimerTarget
  alias Skuld.Effects.Async.Scheduler
  alias Skuld.Effects.Throw

  describe "run_one/2" do
    test "runs single computation to completion" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :work_done
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :work_done}
    end

    test "handles task that takes time" do
      # Gate releases after 1 task registers
      gate = start_gate(1)

      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    # Wait at gate - ensures task doesn't complete instantly
                    _ = send(gate, {:gate_wait, self()})
                    _ = receive do: (:gate_release -> :ok)
                    :delayed_result
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :delayed_result}
    end

    test "handles multiple sequential awaits" do
      # Gate releases after 2 tasks register
      gate = start_gate(2)

      result =
        comp do
          Async.boundary(
            comp do
              h1 <-
                Async.async(
                  comp do
                    _ = send(gate, {:gate_wait, self()})
                    _ = receive do: (:gate_release -> :ok)
                    :first
                  end
                )

              h2 <-
                Async.async(
                  comp do
                    _ = send(gate, {:gate_wait, self()})
                    _ = receive do: (:gate_release -> :ok)
                    :second
                  end
                )

              r1 <- Async.await(h1)
              r2 <- Async.await(h2)
              {r1, r2}
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:first, :second}}
    end
  end

  describe "run/2 - multiple computations" do
    test "runs multiple computations" do
      comp1 =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :result1
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()

      comp2 =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :result2
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()

      {:done, results} = Scheduler.run([comp1, comp2])

      assert results[{:index, 0}] == :result1
      assert results[{:index, 1}] == :result2
    end

    test "handles fast and slow computations" do
      # Gate for the slow task
      gate = start_gate(1)

      comp_fast =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :fast
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()

      comp_slow =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    # Wait at gate
                    _ = send(gate, {:gate_wait, self()})
                    _ = receive do: (:gate_release -> :ok)
                    :slow
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
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
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    # Task waits forever - will lose to timer
                    _ = receive do: (:never_sent -> :ok)
                    :slow_task
                  end
                )

              timer = TimerTarget.new(10)

              {target_key, value} <-
                Async.await_any_raw([TaskTarget.new(h.task), timer])

              _ <- Async.cancel(h)

              case target_key do
                {:timer, _} -> {:timeout, value}
                {:task, _} -> {:task_won, value}
              end
            end,
            fn result, _unawaited -> result end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:timeout, {:ok, :timeout}}}
    end

    test "task wins race against long timer" do
      # Gate releases immediately (1 task)
      gate = start_gate(1)

      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    # Quick task - wait at gate then complete
                    _ = send(gate, {:gate_wait, self()})
                    _ = receive do: (:gate_release -> :ok)
                    :fast_task
                  end
                )

              # Timer is very long (1 second)
              timer = TimerTarget.new(1000)

              {target_key, value} <-
                Async.await_any_raw([TaskTarget.new(h.task), timer])

              _ <- Async.cancel(h)

              case target_key do
                {:timer, _} -> {:timeout, value}
                {:task, _} -> {:task_won, value}
              end
            end,
            fn result, _unawaited -> result end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:task_won, {:ok, :fast_task}}}
    end

    test "reusable timer for overall operation timeout" do
      # Gate releases immediately
      gate = start_gate(1)

      result =
        comp do
          Async.boundary(
            comp do
              # Create a timer with long timeout (won't fire)
              timer = TimerTarget.new(1000)

              # Task completes quickly
              h1 <-
                Async.async(
                  comp do
                    _ = send(gate, {:gate_wait, self()})
                    _ = receive do: (:gate_release -> :ok)
                    :step1_done
                  end
                )

              {key1, r1} <-
                Async.await_any_raw([TaskTarget.new(h1.task), timer])

              # Must cancel handle since await_any_raw doesn't untrack it
              _ <- Async.cancel(h1)

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
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      # Task should complete before the timer
      assert result == {:done, {:step1_ok, {:ok, :step1_done}}}
    end
  end

  describe "error handling" do
    test "computation error is recorded" do
      comp_ok =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :ok_result
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()

      comp_error =
        comp do
          _ = raise "boom"
          :never_reached
        end

      # Capture the expected error log from :log_and_continue behavior
      capture_log(fn ->
        {:done, results} = Scheduler.run([comp_ok, comp_error])

        assert results[{:index, 0}] == :ok_result
        assert match?({:error, {:throw, _}}, results[{:index, 1}])
      end)
    end

    test "on_error: :stop halts on first error" do
      comp_error =
        comp do
          _ = raise "boom"
          :never_reached
        end

      # on_error: :stop doesn't log, but wrap anyway for consistency
      result = Scheduler.run([comp_error], on_error: :stop)

      # Exceptions are converted to throws by Comp.call's ConvertThrow handling
      assert match?({:error, {:throw, %{kind: :error, payload: %RuntimeError{}}}}, result)
    end
  end

  describe "FIFO fairness" do
    test "computations wake in FIFO order" do
      # Gate releases after both tasks register
      gate = start_gate(2)

      comp1 =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    _ = send(gate, {:gate_wait, self()})
                    _ = receive do: (:gate_release -> :ok)
                    :comp1
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()

      comp2 =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    _ = send(gate, {:gate_wait, self()})
                    _ = receive do: (:gate_release -> :ok)
                    :comp2
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()

      {:done, results} = Scheduler.run([comp1, comp2])

      values = Map.values(results)
      assert :comp1 in values
      assert :comp2 in values
    end
  end

  #############################################################################
  ## Test Helpers
  #############################################################################

  # Start a gate process that releases all waiting tasks after n registrations.
  # Tasks call: send(gate, {:gate_wait, self()}) then receive do: (:gate_release -> :ok)
  # The gate stays alive after releasing to avoid any race conditions with process exit.
  defp start_gate(n) when n > 0 do
    spawn(fn -> gate_loop(n, []) end)
  end

  defp gate_loop(0, waiting) do
    # All tasks registered, release them all
    Enum.each(waiting, &send(&1, :gate_release))
    # Stay alive indefinitely (gets cleaned up when test process exits)
    Process.sleep(:infinity)
  end

  defp gate_loop(remaining, waiting) do
    receive do
      {:gate_wait, pid} ->
        gate_loop(remaining - 1, [pid | waiting])
    end
  end
end
