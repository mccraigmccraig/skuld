defmodule Skuld.Effects.FiberPoolTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.FiberPool
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Writer

  describe "fiber and await" do
    test "runs and awaits a pure computation as fiber" do
      result =
        comp do
          h <- FiberPool.fiber(Comp.pure(42))
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "runs and awaits a computation that transforms a value as fiber" do
      result =
        comp do
          h <- FiberPool.fiber(Comp.pure(21) |> Comp.map(&(&1 * 2)))
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "runs multiple fibers and awaits them sequentially" do
      result =
        comp do
          h1 <- FiberPool.fiber(Comp.pure(10))
          h2 <- FiberPool.fiber(Comp.pure(20))
          h3 <- FiberPool.fiber(Comp.pure(12))

          r1 <- FiberPool.await!(h1)
          r2 <- FiberPool.await!(h2)
          r3 <- FiberPool.await!(h3)

          r1 + r2 + r3
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "fiber can use effects with installed handlers" do
      fiber_comp =
        comp do
          x <- State.get()
          _ <- State.put(x + 10)
          State.get()
        end
        |> State.with_handler(32)

      result =
        comp do
          h <- FiberPool.fiber(fiber_comp)
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end
  end

  describe "await_all" do
    test "awaits multiple fibers at once" do
      result =
        comp do
          h1 <- FiberPool.fiber(Comp.pure(10))
          h2 <- FiberPool.fiber(Comp.pure(20))
          h3 <- FiberPool.fiber(Comp.pure(12))

          FiberPool.await_all!([h1, h2, h3])
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [10, 20, 12]
    end

    test "await_all with empty list returns empty list" do
      result =
        comp do
          FiberPool.await_all!([])
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == []
    end

    test "await_all preserves order" do
      result =
        comp do
          h1 <- FiberPool.fiber(Comp.pure(:first))
          h2 <- FiberPool.fiber(Comp.pure(:second))
          h3 <- FiberPool.fiber(Comp.pure(:third))

          FiberPool.await_all!([h3, h1, h2])
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [:third, :first, :second]
    end
  end

  describe "await_any" do
    test "returns first completed fiber" do
      {handle, result} =
        comp do
          h1 <- FiberPool.fiber(Comp.pure(:one))
          h2 <- FiberPool.fiber(Comp.pure(:two))

          FiberPool.await_any!([h1, h2])
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      # Should return one of the handles and its result
      assert result in [:one, :two]
      assert handle != nil
    end
  end

  describe "cancel" do
    test "cancel returns :ok" do
      result =
        comp do
          h <- FiberPool.fiber(Comp.pure(42))
          FiberPool.cancel(h)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == :ok
    end
  end

  describe "error handling" do
    test "fiber error is propagated on await" do
      fiber_comp = fn _env, _k ->
        raise "fiber error"
      end

      error =
        assert_raise Skuld.Comp.ThrowError, fn ->
          comp do
            h <- FiberPool.fiber(fiber_comp)
            FiberPool.await!(h)
          end
          |> FiberPool.with_handler()
          |> Comp.run!()
        end

      # The raise inside the fiber is caught by Comp.call and converted to a
      # Comp.Throw, which execute_and_handle stores as {:throw, throw.error}.
      # unwrap_result unwraps the Comp.Throw wrapper back to :exception type.
      assert %Skuld.Effects.FiberPool.AwaitError{
               type: :exception,
               error: %RuntimeError{message: "fiber error"},
               stacktrace: stacktrace
             } = error.error

      assert is_list(stacktrace) and stacktrace != []
    end
  end

  describe "no fibers" do
    test "computation without fibers completes normally" do
      result =
        comp do
          x = 40
          y = 2
          x + y
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end
  end

  describe "run vs run!" do
    test "run returns {result, env} tuple" do
      {result, env} =
        comp do
          h <- FiberPool.fiber(Comp.pure(42))
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> Comp.run()

      assert result == 42
      assert env != nil
    end
  end

  describe "scope" do
    test "scope awaits all spawned fibers before returning" do
      # Use state to track that both fibers completed
      fiber1 =
        comp do
          x <- State.get()
          _ <- State.put(x + 10)
          :fiber1_done
        end
        |> State.with_handler(0)

      fiber2 =
        comp do
          x <- State.get()
          _ <- State.put(x + 100)
          :fiber2_done
        end
        |> State.with_handler(0)

      result =
        comp do
          FiberPool.scope(
            comp do
              _ <- FiberPool.fiber(fiber1)
              _ <- FiberPool.fiber(fiber2)
              :scope_body_done
            end
          )
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      # Scope returns the body's result
      assert result == :scope_body_done
    end

    test "scope returns body result even with awaited fibers" do
      result =
        comp do
          FiberPool.scope(
            comp do
              h <- FiberPool.fiber(Comp.pure(100))
              r <- FiberPool.await!(h)
              r + 5
            end
          )
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 105
    end

    test "nested scopes work correctly" do
      result =
        comp do
          FiberPool.scope(
            comp do
              h1 <- FiberPool.fiber(Comp.pure(10))

              inner_result <-
                FiberPool.scope(
                  comp do
                    h2 <- FiberPool.fiber(Comp.pure(20))
                    FiberPool.await!(h2)
                  end
                )

              outer_result <- FiberPool.await!(h1)
              {outer_result, inner_result}
            end
          )
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == {10, 20}
    end

    test "scope with on_exit callback" do
      # Track that on_exit was called
      on_exit_comp = fn result, handles ->
        Comp.pure({:exit_called, result, length(handles)})
      end

      result =
        comp do
          FiberPool.scope(
            comp do
              _ <- FiberPool.fiber(Comp.pure(1))
              _ <- FiberPool.fiber(Comp.pure(2))
              :body_done
            end,
            on_exit: on_exit_comp
          )
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      # Scope still returns body result
      assert result == :body_done
    end

    test "scope with no fibers spawned" do
      result =
        comp do
          FiberPool.scope(
            comp do
              x = 40
              y = 2
              x + y
            end
          )
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "scope cancels fibers when body throws" do
      result =
        comp do
          Throw.try_catch(
            comp do
              FiberPool.scope(
                comp do
                  _ <- FiberPool.fiber(Comp.pure(:a))
                  _ <- FiberPool.fiber(Comp.pure(:b))
                  Throw.throw(:scope_error)
                end
              )
            end
          )
        end
        |> FiberPool.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert {:error, :scope_error} = result
    end

    test "scope error propagates through outer catch" do
      result =
        comp do
          Throw.catch_error(
            comp do
              FiberPool.scope(
                comp do
                  _ <- FiberPool.fiber(Comp.pure(:ignored))
                  Throw.throw(:boom)
                end
              )
            end,
            fn :boom -> Comp.pure(:recovered) end
          )
        end
        |> FiberPool.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :recovered
    end

    test "scope error with no fibers still propagates" do
      result =
        comp do
          Throw.try_catch(
            comp do
              FiberPool.scope(
                comp do
                  Throw.throw(:no_fibers_error)
                end
              )
            end
          )
        end
        |> FiberPool.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert {:error, :no_fibers_error} = result
    end

    test "scope success still works when Throw handler is installed" do
      result =
        comp do
          FiberPool.scope(
            comp do
              h <- FiberPool.fiber(Comp.pure(42))
              FiberPool.await!(h)
            end
          )
        end
        |> FiberPool.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == 42
    end
  end

  describe "task" do
    test "runs and awaits a task" do
      result =
        comp do
          h <- FiberPool.task(fn -> 42 end)
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> FiberPool.with_task_supervisor()
        |> Comp.run!()

      assert result == 42
    end

    test "task runs in parallel process" do
      # Use self() to verify task runs in different process
      parent = self()

      result =
        comp do
          h <- FiberPool.task(fn -> self() != parent end)
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> FiberPool.with_task_supervisor()
        |> Comp.run!()

      # Task should have run in a different process
      assert result == true
    end

    test "runs multiple tasks and awaits all" do
      result =
        comp do
          h1 <- FiberPool.task(fn -> 10 end)
          h2 <- FiberPool.task(fn -> 20 end)
          h3 <- FiberPool.task(fn -> 12 end)

          FiberPool.await_all!([h1, h2, h3])
        end
        |> FiberPool.with_handler()
        |> FiberPool.with_task_supervisor()
        |> Comp.run!()

      assert result == [10, 20, 12]
    end

    test "task that crashes returns error on await" do
      # Task crashes are wrapped as {:task_crashed, reason}
      # Use capture_log to suppress the expected Task error log
      import ExUnit.CaptureLog

      capture_log(fn ->
        error =
          assert_raise Skuld.Comp.ThrowError, fn ->
            comp do
              h <- FiberPool.task(fn -> raise "task crashed!" end)
              FiberPool.await!(h)
            end
            |> FiberPool.with_handler()
            |> FiberPool.with_task_supervisor()
            |> Comp.run!()
          end

        assert %Skuld.Effects.FiberPool.AwaitError{
                 type: :exception,
                 error: %RuntimeError{message: "task crashed!"}
               } = error.error
      end)
    end

    test "mixed fibers and tasks" do
      result =
        comp do
          # Submit both fibers and tasks
          fiber_h <- FiberPool.fiber(Comp.pure(:fiber_result))
          task_h <- FiberPool.task(fn -> :task_result end)

          # Await both
          fiber_r <- FiberPool.await!(fiber_h)
          task_r <- FiberPool.await!(task_h)

          {fiber_r, task_r}
        end
        |> FiberPool.with_handler()
        |> FiberPool.with_task_supervisor()
        |> Comp.run!()

      assert result == {:fiber_result, :task_result}
    end

    test "tasks without explicit await still run" do
      # Tasks that aren't awaited will still run, but we need to await something
      # to trigger the scheduler to wait for task completion
      result =
        comp do
          h1 <- FiberPool.task(fn -> 100 end)
          _ <- FiberPool.task(fn -> :ignored end)
          # Only await h1
          FiberPool.await!(h1)
        end
        |> FiberPool.with_handler()
        |> FiberPool.with_task_supervisor()
        |> Comp.run!()

      assert result == 100
    end

    test "await_any with tasks" do
      {_handle, result} =
        comp do
          h1 <- FiberPool.task(fn -> :first end)
          h2 <- FiberPool.task(fn -> :second end)

          FiberPool.await_any!([h1, h2])
        end
        |> FiberPool.with_handler()
        |> FiberPool.with_task_supervisor()
        |> Comp.run!()

      assert result in [:first, :second]
    end

    test "task without supervisor raises clear error" do
      assert_raise ArgumentError, ~r/FiberPool.task\/2 requires a Task.Supervisor/, fn ->
        comp do
          h <- FiberPool.task(fn -> 42 end)
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()
      end
    end

    test "with_task_supervisor with provided supervisor" do
      {:ok, sup} = Task.Supervisor.start_link()

      result =
        comp do
          h <- FiberPool.task(fn -> 42 end)
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> FiberPool.with_task_supervisor(supervisor: sup)
        |> Comp.run!()

      assert result == 42
      # Supervisor should still be alive (caller manages lifecycle)
      assert Process.alive?(sup)
      Supervisor.stop(sup)
    end
  end

  describe "env_state propagation from fire-and-forget fibers" do
    test "writer accumulations from un-awaited fibers are propagated back" do
      # Fire-and-forget fibers that write to a shared Writer log.
      # The main computation finishes immediately, so the fibers are drained
      # via the run_fibers_to_completion path. Their Writer.tell side-effects
      # must be propagated back into the final env_state.
      {result, log} =
        comp do
          _ <-
            FiberPool.fiber(
              comp do
                Writer.tell(:fiber_a)
              end
            )

          _ <-
            FiberPool.fiber(
              comp do
                Writer.tell(:fiber_b)
              end
            )

          :main_done
        end
        |> FiberPool.with_handler()
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Comp.run!()

      assert result == :main_done
      assert Enum.sort(log) == [:fiber_a, :fiber_b]
    end

    test "writer accumulations from un-awaited fibers combine with main computation writes" do
      {result, log} =
        comp do
          _ <- Writer.tell(:from_main)

          _ <-
            FiberPool.fiber(
              comp do
                Writer.tell(:from_fiber)
              end
            )

          :done
        end
        |> FiberPool.with_handler()
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Comp.run!()

      assert result == :done
      assert :from_main in log
      assert :from_fiber in log
    end
  end
end
