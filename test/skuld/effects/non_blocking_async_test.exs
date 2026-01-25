defmodule Skuld.Effects.NonBlockingAsyncTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Effects.NonBlockingAsync
  alias Skuld.Effects.NonBlockingAsync.Scheduler
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
                    _ = Process.sleep(100)
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
    end
  end

  describe "fast path" do
    test "already-completed task returns immediately without yielding" do
      # This tests that Task.yield(task, 0) fast-path works
      result =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    :instant
                  end
                )

              # Give time for task to complete
              _ = Process.sleep(10)
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
end
