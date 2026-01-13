defmodule Skuld.Effects.AsyncTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Async
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  # Helper to avoid "pattern will never match" warning on raise
  # Using apply/3 hides the none() return type from the type checker
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp boom!, do: apply(Kernel, :raise, ["boom!"])

  describe "with_handler (production)" do
    test "basic async/await works" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :done
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :done
    end

    test "multiple async tasks" do
      result =
        comp do
          Async.boundary(
            comp do
              h1 <-
                Async.async(
                  comp do
                    :a
                  end
                )

              h2 <-
                Async.async(
                  comp do
                    :b
                  end
                )

              h3 <-
                Async.async(
                  comp do
                    :c
                  end
                )

              r1 <- Async.await(h1)
              r2 <- Async.await(h2)
              r3 <- Async.await(h3)

              {r1, r2, r3}
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:a, :b, :c}
    end

    test "async outside boundary throws error" do
      result =
        comp do
          Async.async(
            comp do
              :work
            end
          )
        catch
          err -> {:caught, err}
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:caught, {:error, :async_outside_boundary}}
    end

    test "unawaited tasks throw by default" do
      result =
        comp do
          Async.boundary(
            comp do
              _ <-
                Async.async(
                  comp do
                    :unawaited
                  end
                )

              :done
            end
          )
        catch
          err -> {:caught, err}
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:caught, {:unawaited_tasks, 1}}
    end

    test "custom on_unawaited handler - return result" do
      result =
        comp do
          Async.boundary(
            comp do
              _ <-
                Async.async(
                  comp do
                    :ignored
                  end
                )

              :done
            end,
            fn result, _unawaited -> result end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :done
    end

    test "custom on_unawaited handler - wrap result" do
      result =
        comp do
          Async.boundary(
            comp do
              _ <-
                Async.async(
                  comp do
                    :ignored1
                  end
                )

              _ <-
                Async.async(
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
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == %{result: :done, killed: 2}
    end

    test "nested boundaries are independent" do
      result =
        comp do
          Async.boundary(
            comp do
              h1 <-
                Async.async(
                  comp do
                    :outer
                  end
                )

              inner_result <-
                Async.boundary(
                  comp do
                    h2 <-
                      Async.async(
                        comp do
                          :inner
                        end
                      )

                    Async.await(h2)
                  end
                )

              outer_result <- Async.await(h1)
              {outer_result, inner_result}
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:outer, :inner}
    end

    test "await across boundary throws error" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :outer
                  end
                )

              Async.boundary(
                comp do
                  # Try to await outer handle from inner boundary
                  Async.await(h)
                end
              )
            end
          )
        catch
          err -> {:caught, err}
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:caught, {:error, :await_across_boundary}}
    end

    test "async tasks run concurrently" do
      # Start multiple tasks that each sleep and return
      start_time = System.monotonic_time(:millisecond)

      result =
        comp do
          Async.boundary(
            comp do
              h1 <-
                Async.async(
                  comp do
                    Process.sleep(50)
                    :a
                  end
                )

              h2 <-
                Async.async(
                  comp do
                    Process.sleep(50)
                    :b
                  end
                )

              h3 <-
                Async.async(
                  comp do
                    Process.sleep(50)
                    :c
                  end
                )

              r1 <- Async.await(h1)
              r2 <- Async.await(h2)
              r3 <- Async.await(h3)

              {r1, r2, r3}
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert result == {:a, :b, :c}
      # If sequential, would take ~150ms. Parallel should be ~50-100ms
      assert elapsed < 120
    end

    test "task failure is caught" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    boom!()
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert match?({:error, {:task_failed, _}}, result)
    end

    test "cancel removes task from unawaited set" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :will_be_cancelled
                  end
                )

              _ <- Async.cancel(h)
              :done
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # No unawaited error because we cancelled
      assert result == :done
    end

    test "cancel returns :ok" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :work
                  end
                )

              cancel_result <- Async.cancel(h)
              cancel_result
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :ok
    end

    test "cancel across boundary throws error" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :outer_task
                  end
                )

              inner_result <-
                Async.boundary(
                  comp do
                    # Try to cancel outer handle from inner boundary
                    Async.cancel(h)
                  end
                )

              inner_result
            end
          )
        catch
          err -> {:caught, err}
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:caught, {:error, :cancel_across_boundary}}
    end

    test "cancel one task, await another" do
      result =
        comp do
          Async.boundary(
            comp do
              h1 <-
                Async.async(
                  comp do
                    :approach_a
                  end
                )

              h2 <-
                Async.async(
                  comp do
                    :approach_b
                  end
                )

              r1 <- Async.await(h1)
              _ <- Async.cancel(h2)
              r1
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :approach_a
    end

    test "cancel already-completed task is no-op" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :done
                  end
                )

              # Await first
              r <- Async.await(h)
              # Then cancel (already completed and awaited)
              cancel_result <- Async.cancel(h)
              {r, cancel_result}
            end
          )
        end
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # Cancel returns :ok even for already-awaited tasks
      assert result == {:done, :ok}
    end
  end

  describe "with_sequential_handler (testing)" do
    test "basic async/await works" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :done
                  end
                )

              Async.await(h)
            end
          )
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :done
    end

    test "multiple async tasks" do
      result =
        comp do
          Async.boundary(
            comp do
              h1 <-
                Async.async(
                  comp do
                    :a
                  end
                )

              h2 <-
                Async.async(
                  comp do
                    :b
                  end
                )

              h3 <-
                Async.async(
                  comp do
                    :c
                  end
                )

              r1 <- Async.await(h1)
              r2 <- Async.await(h2)
              r3 <- Async.await(h3)

              {r1, r2, r3}
            end
          )
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:a, :b, :c}
    end

    test "async outside boundary throws error" do
      result =
        comp do
          Async.async(
            comp do
              :work
            end
          )
        catch
          err -> {:caught, err}
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:caught, {:error, :async_outside_boundary}}
    end

    test "unawaited tasks throw by default" do
      result =
        comp do
          Async.boundary(
            comp do
              _ <-
                Async.async(
                  comp do
                    :unawaited
                  end
                )

              :done
            end
          )
        catch
          err -> {:caught, err}
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:caught, {:unawaited_tasks, 1}}
    end

    test "custom on_unawaited handler" do
      result =
        comp do
          Async.boundary(
            comp do
              _ <-
                Async.async(
                  comp do
                    :ignored
                  end
                )

              :done
            end,
            fn result, _unawaited -> result end
          )
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :done
    end

    test "nested boundaries are independent" do
      result =
        comp do
          Async.boundary(
            comp do
              h1 <-
                Async.async(
                  comp do
                    :outer
                  end
                )

              inner_result <-
                Async.boundary(
                  comp do
                    h2 <-
                      Async.async(
                        comp do
                          :inner
                        end
                      )

                    Async.await(h2)
                  end
                )

              outer_result <- Async.await(h1)
              {outer_result, inner_result}
            end
          )
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:outer, :inner}
    end

    test "await across boundary throws error" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :outer
                  end
                )

              Async.boundary(
                comp do
                  Async.await(h)
                end
              )
            end
          )
        catch
          err -> {:caught, err}
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:caught, {:error, :await_across_boundary}}
    end

    test "async tasks with State effect" do
      result =
        comp do
          Async.boundary(
            comp do
              h1 <-
                Async.async(
                  comp do
                    count <- State.get()
                    _ <- State.put(count + 1)
                    count
                  end
                )

              h2 <-
                Async.async(
                  comp do
                    count <- State.get()
                    _ <- State.put(count + 10)
                    count
                  end
                )

              r1 <- Async.await(h1)
              r2 <- Async.await(h2)
              final <- State.get()

              {r1, r2, final}
            end
          )
        end
        |> State.with_handler(0)
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # Sequential: h1 runs with state=0, returns 0, sets state=1
      # h2 runs with state=0 (snapshot at fork), returns 0, sets state=10
      # Final state in parent is still 0 (child changes don't propagate)
      # Note: sequential handler still doesn't propagate state changes
      assert result == {0, 0, 0}
    end

    test "cancel removes task from unawaited set" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :will_be_cancelled
                  end
                )

              _ <- Async.cancel(h)
              :done
            end
          )
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # No unawaited error because we cancelled
      assert result == :done
    end

    test "cancel returns :ok" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :work
                  end
                )

              cancel_result <- Async.cancel(h)
              cancel_result
            end
          )
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :ok
    end

    test "cancel across boundary throws error" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :outer_task
                  end
                )

              inner_result <-
                Async.boundary(
                  comp do
                    # Try to cancel outer handle from inner boundary
                    Async.cancel(h)
                  end
                )

              inner_result
            end
          )
        catch
          err -> {:caught, err}
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:caught, {:error, :cancel_across_boundary}}
    end

    test "cancel one task, await another" do
      result =
        comp do
          Async.boundary(
            comp do
              h1 <-
                Async.async(
                  comp do
                    :approach_a
                  end
                )

              h2 <-
                Async.async(
                  comp do
                    :approach_b
                  end
                )

              r1 <- Async.await(h1)
              _ <- Async.cancel(h2)
              r1
            end
          )
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :approach_a
    end

    test "cancel already-awaited task is no-op" do
      result =
        comp do
          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    :done
                  end
                )

              # Await first
              r <- Async.await(h)
              # Then cancel (already awaited)
              cancel_result <- Async.cancel(h)
              {r, cancel_result}
            end
          )
        end
        |> Async.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # Cancel returns :ok even for already-awaited tasks
      assert result == {:done, :ok}
    end
  end

  describe "state isolation" do
    test "child task gets snapshot of parent state (production)" do
      result =
        comp do
          _ <- State.put(100)

          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    # Should see 100 from parent
                    State.get()
                  end
                )

              # Modify parent state after fork
              _ <- State.put(200)

              child_saw <- Async.await(h)
              parent_has <- State.get()

              {child_saw, parent_has}
            end
          )
        end
        |> State.with_handler(0)
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # Child saw 100 (snapshot at fork), parent has 200
      assert result == {100, 200}
    end

    test "child state changes don't propagate to parent (production)" do
      result =
        comp do
          _ <- State.put(100)

          Async.boundary(
            comp do
              h <-
                Async.async(
                  comp do
                    _ <- State.put(999)
                    :done
                  end
                )

              _ <- Async.await(h)
              State.get()
            end
          )
        end
        |> State.with_handler(0)
        |> Async.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # Parent still has 100, not affected by child's put(999)
      assert result == 100
    end
  end
end
