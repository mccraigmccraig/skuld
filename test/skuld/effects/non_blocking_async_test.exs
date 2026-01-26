defmodule Skuld.Effects.NonBlockingAsyncTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.NonBlockingAsync
  alias Skuld.Effects.NonBlockingAsync.Scheduler
  alias Skuld.Effects.Reader
  alias Skuld.Effects.Throw

  # Helper to raise without triggering "typing violation" warnings.
  # Must be public (def) since async tasks run in separate processes.
  def boom!(msg \\ "boom!") do
    if true, do: raise(msg), else: :ok
  end

  describe "basic async/await" do
    test "single async/await works" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :done
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :done}
    end

    test "multiple async tasks" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.async(
                  comp do
                    :a
                  end
                )

              h2 <-
                NonBlockingAsync.async(
                  comp do
                    :b
                  end
                )

              h3 <-
                NonBlockingAsync.async(
                  comp do
                    :c
                  end
                )

              r1 <- NonBlockingAsync.await(h1)
              r2 <- NonBlockingAsync.await(h2)
              r3 <- NonBlockingAsync.await(h3)

              {r1, r2, r3}
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:a, :b, :c}}
    end

    test "async outside boundary returns error" do
      result =
        comp do
          NonBlockingAsync.async(
            comp do
              :work
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      # Throws from handlers become errors at the scheduler level
      assert result == {:error, {:throw, {:error, :async_outside_boundary}}}
    end
  end

  describe "await_all" do
    test "await_all returns results in order" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.async(
                  comp do
                    :first
                  end
                )

              h2 <-
                NonBlockingAsync.async(
                  comp do
                    :second
                  end
                )

              h3 <-
                NonBlockingAsync.async(
                  comp do
                    :third
                  end
                )

              NonBlockingAsync.await_all([h1, h2, h3])
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, [:first, :second, :third]}
    end

    test "await_all with empty list" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              NonBlockingAsync.await_all([])
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, []}
    end
  end

  describe "await_any" do
    test "await_any returns first completer" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.async(
                  comp do
                    :winner
                  end
                )

              h2 <-
                NonBlockingAsync.async(
                  comp do
                    # Slow task - waits forever, will be cancelled
                    _ =
                      receive do
                        :never_sent -> :ok
                      end

                    :loser
                  end
                )

              {winner, value} <- NonBlockingAsync.await_any([h1, h2])
              _ <- NonBlockingAsync.cancel(h2)
              {winner.task.ref == h1.task.ref, value}
            end,
            fn result, _unawaited -> result end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {true, :winner}}
    end
  end

  describe "boundary cleanup" do
    test "unawaited tasks throw by default" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              _ <-
                NonBlockingAsync.async(
                  comp do
                    :unawaited
                  end
                )

              :done
            end
          )
        catch
          {Throw, err} -> {:caught, err}
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:caught, {:unawaited_tasks, 1}}}
    end

    test "custom on_unawaited handler - return result" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              _ <-
                NonBlockingAsync.async(
                  comp do
                    :ignored
                  end
                )

              :done
            end,
            fn result, _unawaited -> result end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :done}
    end

    test "custom on_unawaited handler - wrap result" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              _ <-
                NonBlockingAsync.async(
                  comp do
                    :ignored1
                  end
                )

              _ <-
                NonBlockingAsync.async(
                  comp do
                    :ignored2
                  end
                )

              :done
            end,
            fn result, unawaited ->
              %{result: result, killed: length(unawaited)}
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, %{result: :done, killed: 2}}
    end
  end

  describe "cancel" do
    test "cancel removes task from unawaited set" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :will_be_cancelled
                  end
                )

              _ <- NonBlockingAsync.cancel(h)
              :done
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      # No unawaited error because we cancelled
      assert result == {:done, :done}
    end

    test "cancel returns :ok" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :work
                  end
                )

              cancel_result <- NonBlockingAsync.cancel(h)
              cancel_result
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :ok}
    end

    test "cancel across boundary returns error" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :outer_task
                  end
                )

              inner_result <-
                NonBlockingAsync.boundary(
                  comp do
                    # Try to cancel outer handle from inner boundary
                    NonBlockingAsync.cancel(h)
                  end
                )

              inner_result
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      # Throws from handlers become errors at the scheduler level
      assert result == {:error, {:throw, {:error, :cancel_across_boundary}}}
    end
  end

  describe "nested boundaries" do
    test "nested boundaries are independent" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.async(
                  comp do
                    :outer
                  end
                )

              inner_result <-
                NonBlockingAsync.boundary(
                  comp do
                    h2 <-
                      NonBlockingAsync.async(
                        comp do
                          :inner
                        end
                      )

                    NonBlockingAsync.await(h2)
                  end
                )

              outer_result <- NonBlockingAsync.await(h1)
              {outer_result, inner_result}
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:outer, :inner}}
    end

    test "await across boundary returns error" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :outer
                  end
                )

              NonBlockingAsync.boundary(
                comp do
                  # Try to await outer handle from inner boundary
                  NonBlockingAsync.await(h)
                end
              )
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      # Throws from handlers become errors at the scheduler level
      assert result == {:error, {:throw, {:error, :await_across_boundary}}}
    end
  end

  describe "task failure" do
    test "task failure returns error" do
      # Capture expected error log from task failure
      capture_log(fn ->
        result =
          comp do
            NonBlockingAsync.boundary(
              comp do
                h <-
                  NonBlockingAsync.async(
                    comp do
                      boom!()
                    end
                  )

                NonBlockingAsync.await(h)
              end
            )
          end
          |> NonBlockingAsync.with_handler()
          |> Throw.with_handler()
          |> Scheduler.run_one()

        # Task failures from await become errors at the scheduler level
        assert match?({:done, {:error, {:throw, {:error, _}}}}, result)
      end)
    end
  end

  describe "fast path" do
    test "already-completed task returns immediately without yielding" do
      # This tests that Task.yield(task, 0) fast-path works
      test_pid = self()

      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    # Signal test process with task pid so it can monitor for completion
                    _ = send(test_pid, {:task_pid, self()})
                    :instant
                  end
                )

              # Wait for task to complete by monitoring its exit
              # The task sends its pid, then we monitor it and wait for DOWN
              _ =
                receive do
                  {:task_pid, task_pid} ->
                    ref = Process.monitor(task_pid)

                    receive do
                      {:DOWN, ^ref, :process, ^task_pid, _} -> :ok
                    end
                end

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :instant}
    end
  end

  #############################################################################
  ## Fiber Tests - Cooperative Scheduling
  #############################################################################

  describe "basic fiber" do
    test "single fiber can be spawned and awaited" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    42
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, 42}
    end

    test "fiber returns FiberHandle" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    :fiber_result
                  end
                )

              # Verify it's a FiberHandle, not a TaskHandle
              is_fiber = match?(%NonBlockingAsync.FiberHandle{}, h)
              r <- NonBlockingAsync.await(h)
              {is_fiber, r}
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {true, :fiber_result}}
    end

    test "fiber outside boundary returns error" do
      result =
        comp do
          NonBlockingAsync.fiber(
            comp do
              :work
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:error, {:throw, {:error, :fiber_outside_boundary}}}
    end
  end

  describe "multiple fibers" do
    test "multiple fibers can be spawned and awaited" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.fiber(
                  comp do
                    :a
                  end
                )

              h2 <-
                NonBlockingAsync.fiber(
                  comp do
                    :b
                  end
                )

              h3 <-
                NonBlockingAsync.fiber(
                  comp do
                    :c
                  end
                )

              r1 <- NonBlockingAsync.await(h1)
              r2 <- NonBlockingAsync.await(h2)
              r3 <- NonBlockingAsync.await(h3)

              {r1, r2, r3}
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:a, :b, :c}}
    end

    test "fibers run cooperatively in single process" do
      # Verify fibers run in the scheduler process, not separate processes
      scheduler_pid = self()

      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    # Fiber runs in scheduler process
                    self() == scheduler_pid
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, true}
    end
  end

  describe "mixed fiber and task" do
    test "fiber and async task can be mixed" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h_fiber <-
                NonBlockingAsync.fiber(
                  comp do
                    :fiber_result
                  end
                )

              h_task <-
                NonBlockingAsync.async(
                  comp do
                    :task_result
                  end
                )

              r1 <- NonBlockingAsync.await(h_fiber)
              r2 <- NonBlockingAsync.await(h_task)
              {r1, r2}
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:fiber_result, :task_result}}
    end

    test "task runs in separate process, fiber runs in scheduler" do
      scheduler_pid = self()

      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h_fiber <-
                NonBlockingAsync.fiber(
                  comp do
                    self()
                  end
                )

              h_task <-
                NonBlockingAsync.async(
                  comp do
                    self()
                  end
                )

              fiber_pid <- NonBlockingAsync.await(h_fiber)
              task_pid <- NonBlockingAsync.await(h_task)

              {fiber_pid == scheduler_pid, task_pid != scheduler_pid}
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {true, true}}
    end
  end

  describe "fiber await_all" do
    test "await_all works with fibers" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.fiber(
                  comp do
                    :first
                  end
                )

              h2 <-
                NonBlockingAsync.fiber(
                  comp do
                    :second
                  end
                )

              h3 <-
                NonBlockingAsync.fiber(
                  comp do
                    :third
                  end
                )

              NonBlockingAsync.await_all([h1, h2, h3])
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, [:first, :second, :third]}
    end

    test "await_all works with mixed fibers and tasks" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.fiber(
                  comp do
                    :fiber
                  end
                )

              h2 <-
                NonBlockingAsync.async(
                  comp do
                    :task
                  end
                )

              NonBlockingAsync.await_all([h1, h2])
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, [:fiber, :task]}
    end
  end

  describe "fiber await_any" do
    test "await_any works with fibers" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.fiber(
                  comp do
                    :first_fiber
                  end
                )

              h2 <-
                NonBlockingAsync.fiber(
                  comp do
                    :second_fiber
                  end
                )

              {winner, value} <- NonBlockingAsync.await_any([h1, h2])
              # Cancel the loser
              loser = if winner == h1, do: h2, else: h1
              _ <- NonBlockingAsync.cancel(loser)
              value
            end,
            fn result, _unawaited -> result end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      # One of the fibers should win
      assert result == {:done, :first_fiber} or result == {:done, :second_fiber}
    end
  end

  describe "nested fibers" do
    test "fiber can spawn another fiber" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.fiber(
                  comp do
                    h2 <-
                      NonBlockingAsync.fiber(
                        comp do
                          :inner
                        end
                      )

                    inner_result <- NonBlockingAsync.await(h2)
                    {:outer, inner_result}
                  end
                )

              NonBlockingAsync.await(h1)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:outer, :inner}}
    end

    test "deeply nested fibers work" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    h2 <-
                      NonBlockingAsync.fiber(
                        comp do
                          h3 <-
                            NonBlockingAsync.fiber(
                              comp do
                                :deep
                              end
                            )

                          NonBlockingAsync.await(h3)
                        end
                      )

                    NonBlockingAsync.await(h2)
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :deep}
    end
  end

  describe "fiber cancel" do
    test "cancel removes fiber from unawaited set" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    :will_be_cancelled
                  end
                )

              _ <- NonBlockingAsync.cancel(h)
              :done
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      # No unawaited error because we cancelled
      assert result == {:done, :done}
    end

    test "cancel fiber returns :ok" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    :work
                  end
                )

              cancel_result <- NonBlockingAsync.cancel(h)
              cancel_result
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, :ok}
    end
  end

  describe "fiber boundary enforcement" do
    test "unawaited fibers throw by default" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              _ <-
                NonBlockingAsync.fiber(
                  comp do
                    :unawaited_fiber
                  end
                )

              :done
            end
          )
        catch
          {Throw, err} -> {:caught, err}
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:caught, {:unawaited_tasks, 1}}}
    end

    test "await fiber across boundary returns error" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    :outer_fiber
                  end
                )

              NonBlockingAsync.boundary(
                comp do
                  # Try to await outer fiber from inner boundary
                  NonBlockingAsync.await(h)
                end
              )
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:error, {:throw, {:error, :await_across_boundary}}}
    end
  end

  describe "with_sequential_handler" do
    test "runs computation and returns result directly" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    42
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_sequential_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "multiple fibers run cooperatively" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.fiber(
                  comp do
                    :first
                  end
                )

              h2 <-
                NonBlockingAsync.fiber(
                  comp do
                    :second
                  end
                )

              r1 <- NonBlockingAsync.await(h1)
              r2 <- NonBlockingAsync.await(h2)
              {r1, r2}
            end
          )
        end
        |> NonBlockingAsync.with_sequential_handler()
        |> Comp.run!()

      assert result == {:first, :second}
    end

    test "nested fibers work" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h1 <-
                NonBlockingAsync.fiber(
                  comp do
                    h2 <-
                      NonBlockingAsync.fiber(
                        comp do
                          :inner
                        end
                      )

                    inner_result <- NonBlockingAsync.await(h2)
                    {:outer, inner_result}
                  end
                )

              NonBlockingAsync.await(h1)
            end
          )
        end
        |> NonBlockingAsync.with_sequential_handler()
        |> Comp.run!()

      assert result == {:outer, :inner}
    end

    test "mixed fibers and tasks work" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h_fiber <-
                NonBlockingAsync.fiber(
                  comp do
                    :fiber_result
                  end
                )

              h_task <-
                NonBlockingAsync.async(
                  comp do
                    :task_result
                  end
                )

              r1 <- NonBlockingAsync.await(h_fiber)
              r2 <- NonBlockingAsync.await(h_task)
              {r1, r2}
            end
          )
        end
        |> NonBlockingAsync.with_sequential_handler()
        |> Comp.run!()

      assert result == {:fiber_result, :task_result}
    end

    test "errors are propagated via Throw" do
      # Throws inside the computation propagate out via Throw.throw
      # Use catch_error to handle the re-thrown error
      result =
        comp do
          r <-
            Throw.catch_error(
              comp do
                NonBlockingAsync.boundary(
                  comp do
                    _ <- Throw.throw(:test_error)
                    :unreachable
                  end
                )
              end
              |> NonBlockingAsync.with_sequential_handler(),
              fn error -> {:caught, error} end
            )

          r
        end
        |> Throw.with_handler()
        |> Comp.run!()

      # Error is wrapped as {:throw, original_error} by scheduler
      assert result == {:caught, {:throw, :test_error}}
    end

    test "can be composed with other effects" do
      # Reader effect works outside the sequential handler
      result =
        comp do
          x <- Reader.ask()

          boundary_result <-
            comp do
              NonBlockingAsync.boundary(
                comp do
                  h <-
                    NonBlockingAsync.fiber(
                      comp do
                        # x is captured from outer scope
                        x * 2
                      end
                    )

                  NonBlockingAsync.await(h)
                end
              )
            end
            |> NonBlockingAsync.with_sequential_handler()

          boundary_result + 1
        end
        |> Throw.with_handler()
        |> Reader.with_handler(10)
        |> Comp.run!()

      assert result == 21
    end
  end

  describe "await_with_timeout" do
    test "returns {:ok, result} when computation completes before timeout" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    :fast_result
                  end
                )

              NonBlockingAsync.await_with_timeout(h, 5000)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:ok, :fast_result}}
    end

    test "returns {:error, :timeout} when timeout fires first" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    # Sleep longer than timeout
                    _ = Process.sleep(1000)
                    :slow_result
                  end
                )

              NonBlockingAsync.await_with_timeout(h, 10)
            end,
            # Don't throw on unawaited - the task will be killed
            fn result, _unawaited -> result end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:error, :timeout}}
    end

    test "works with fiber handle" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.fiber(
                  comp do
                    :fiber_result
                  end
                )

              NonBlockingAsync.await_with_timeout(h, 1000)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:ok, :fiber_result}}
    end

    test "works with task handle" do
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :task_result
                  end
                )

              NonBlockingAsync.await_with_timeout(h, 1000)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:ok, :task_result}}
    end
  end

  describe "timeout" do
    test "returns {:ok, result} when computation completes in time" do
      result =
        comp do
          NonBlockingAsync.timeout(
            5000,
            comp do
              :completed_in_time
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:ok, :completed_in_time}}
    end

    test "returns {:error, :timeout} when computation exceeds timeout" do
      result =
        comp do
          NonBlockingAsync.timeout(
            10,
            comp do
              # This runs as a fiber, so we need to yield to let timer fire
              # Use an async task that sleeps
              h <-
                NonBlockingAsync.async(
                  comp do
                    _ = Process.sleep(1000)
                    :too_slow
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()
        |> Scheduler.run_one()

      assert result == {:done, {:error, :timeout}}
    end

    test "can be used with with_sequential_handler" do
      result =
        comp do
          NonBlockingAsync.timeout(
            5000,
            comp do
              :quick_result
            end
          )
        end
        |> NonBlockingAsync.with_sequential_handler()
        |> Comp.run!()

      assert result == {:ok, :quick_result}
    end
  end
end
