defmodule Skuld.AsyncCoroutineTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.AsyncCoroutine
  alias Skuld.Comp.Cancelled
  alias Skuld.Comp.ExternalSuspend
  alias Skuld.Comp.Throw, as: ThrowStruct
  alias Skuld.Effects.Reader
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield

  describe "start/2" do
    test "runs a simple computation and sends result" do
      computation =
        comp do
          {:ok, 42}
        end

      {:ok, _runner} = AsyncCoroutine.run(computation, tag: :test)

      assert_receive {AsyncCoroutine, :test, {:ok, 42}}
    end

    test "computation can use effects" do
      computation =
        comp do
          x <- Reader.ask()
          y <- State.get()
          x + y
        end
        |> Reader.with_handler(10)
        |> State.with_handler(32)

      {:ok, _runner} = AsyncCoroutine.run(computation, tag: :with_effects)

      assert_receive {AsyncCoroutine, :with_effects, 42}
    end

    test "sends throw errors" do
      computation =
        comp do
          _ <- Throw.throw(:something_went_wrong)
          :never_reached
        end

      {:ok, _runner} = AsyncCoroutine.run(computation, tag: :throwing)

      assert_receive {AsyncCoroutine, :throwing, %ThrowStruct{error: :something_went_wrong}}
    end

    test "sends yields and waits for resume" do
      computation =
        comp do
          x <- Yield.yield(:first)
          y <- Yield.yield(:second)
          x + y
        end

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :yielding)

      # First yield (data is nil since no scoped effects with suspend decoration)
      assert_receive {AsyncCoroutine, :yielding, %ExternalSuspend{value: :first}}
      AsyncCoroutine.run(runner, 10)

      # Second yield
      assert_receive {AsyncCoroutine, :yielding, %ExternalSuspend{value: :second}}
      AsyncCoroutine.run(runner, 32)

      # Final result
      assert_receive {AsyncCoroutine, :yielding, 42}
    end

    test "uses custom caller" do
      test_pid = self()

      # Spawn a middleman that forwards messages
      middleman =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:forwarded, msg})
          end
        end)

      computation = comp(do: :hello)

      {:ok, _runner} = AsyncCoroutine.run(computation, tag: :custom_caller, caller: middleman)

      assert_receive {:forwarded, {AsyncCoroutine, :custom_caller, :hello}}
    end
  end

  describe "start_sync/2" do
    test "returns first yield synchronously" do
      computation =
        comp do
          x <- Yield.yield(:ready)
          x * 2
        end

      {:ok, runner, %ExternalSuspend{value: :ready}} =
        AsyncCoroutine.run_sync(computation, tag: :sync_start)

      # Can continue with resume_sync
      assert 42 = AsyncCoroutine.run_sync(runner, 21)
    end

    test "returns result when computation completes immediately" do
      computation = comp(do: {:ok, 42})

      {:ok, _runner, {:ok, 42}} =
        AsyncCoroutine.run_sync(computation, tag: :immediate_result)
    end

    test "returns throw when computation throws immediately" do
      computation =
        comp do
          _ <- Throw.throw(:immediate_error)
          :never
        end

      {:ok, _runner, %ThrowStruct{error: :immediate_error}} =
        AsyncCoroutine.run_sync(computation, tag: :immediate_throw)
    end

    test "works with effects" do
      computation =
        comp do
          base <- Reader.ask()
          multiplier <- Yield.yield(:get_multiplier)
          base * multiplier
        end
        |> Reader.with_handler(21)

      {:ok, runner, %ExternalSuspend{value: :get_multiplier}} =
        AsyncCoroutine.run_sync(computation, tag: :with_effects)

      assert 42 = AsyncCoroutine.run_sync(runner, 2)
    end

    test "respects custom timeout" do
      computation =
        comp do
          x <- Yield.yield(:first)
          x
        end

      # Should succeed quickly with reasonable timeout
      {:ok, runner, %ExternalSuspend{value: :first}} =
        AsyncCoroutine.run_sync(computation, tag: :custom_timeout, timeout: 1000)

      assert :done = AsyncCoroutine.run_sync(runner, :done)
    end

    test "command processor pattern - sync start then sync resume loop" do
      # Simulates a command processor that yields ready, processes commands, yields ready again
      processor =
        comp do
          cmd1 <- Yield.yield(:ready)
          result1 = {:processed, cmd1}
          cmd2 <- Yield.yield({:ready, result1})
          result2 = {:processed, cmd2}
          {:done, result1, result2}
        end

      # Start sync - get first :ready yield
      {:ok, runner, %ExternalSuspend{value: :ready}} =
        AsyncCoroutine.run_sync(processor, tag: :processor)

      # Send first command, get back ready with result
      %ExternalSuspend{value: {:ready, {:processed, :cmd_a}}} =
        AsyncCoroutine.run_sync(runner, :cmd_a)

      # Send second command, get final result
      {:done, {:processed, :cmd_a}, {:processed, :cmd_b}} =
        AsyncCoroutine.run_sync(runner, :cmd_b)
    end
  end

  describe "resume_sync/3" do
    test "waits for next yield" do
      computation =
        comp do
          x <- Yield.yield(:first)
          y <- Yield.yield(:second)
          x + y
        end

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :sync_yield)

      # First yield comes via message
      assert_receive {AsyncCoroutine, :sync_yield, %ExternalSuspend{value: :first}}

      # Resume sync and wait for second yield
      assert %ExternalSuspend{value: :second} = AsyncCoroutine.run_sync(runner, 10)

      # Resume sync and wait for result
      assert 42 = AsyncCoroutine.run_sync(runner, 32)
    end

    test "returns result when computation completes" do
      computation =
        comp do
          x <- Yield.yield(:get_value)
          {:ok, x * 2}
        end

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :sync_result)

      assert_receive {AsyncCoroutine, :sync_result, %ExternalSuspend{value: :get_value}}
      assert {:ok, 42} = AsyncCoroutine.run_sync(runner, 21)
    end

    test "returns throw on error" do
      computation =
        comp do
          x <- Yield.yield(:get_value)
          _ <- if x < 0, do: Throw.throw(:negative)
          x
        end

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :sync_throw)

      assert_receive {AsyncCoroutine, :sync_throw, %ExternalSuspend{value: :get_value}}
      assert %ThrowStruct{error: :negative} = AsyncCoroutine.run_sync(runner, -5)
    end

    test "respects custom timeout" do
      # Create a computation where we can control timing
      computation =
        comp do
          _ <- Yield.yield(:ready)
          :done
        end

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :custom_timeout)

      assert_receive {AsyncCoroutine, :custom_timeout, %ExternalSuspend{value: :ready}}

      # This should succeed quickly
      assert :done = AsyncCoroutine.run_sync(runner, :go, timeout: 1000)
    end

    test "mixed sync and async resumes" do
      computation =
        comp do
          a <- Yield.yield(:a)
          b <- Yield.yield(:b)
          c <- Yield.yield(:c)
          a + b + c
        end

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :mixed)

      # First yield via message
      assert_receive {AsyncCoroutine, :mixed, %ExternalSuspend{value: :a}}

      # Async resume
      AsyncCoroutine.run(runner, 1)
      assert_receive {AsyncCoroutine, :mixed, %ExternalSuspend{value: :b}}

      # Sync resume
      assert %ExternalSuspend{value: :c} = AsyncCoroutine.run_sync(runner, 2)

      # Sync resume to completion
      assert 6 = AsyncCoroutine.run_sync(runner, 3)
    end
  end

  describe "cancel/1" do
    test "cancels a yielded computation" do
      computation =
        comp do
          _ <- Yield.yield(:waiting)
          :completed
        end

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :cancellable)

      assert_receive {AsyncCoroutine, :cancellable, %ExternalSuspend{value: :waiting}}

      AsyncCoroutine.cancel(runner)

      assert_receive {AsyncCoroutine, :cancellable, %Cancelled{reason: :cancelled}}
      refute_receive {AsyncCoroutine, :cancellable, _}, 10
    end

    test "cancellation invokes leave_scope for effect cleanup" do
      # Use an agent to track cleanup across process boundaries
      {:ok, agent} = Agent.start_link(fn -> [] end)

      computation =
        Yield.yield(:waiting)
        |> Skuld.Comp.scoped(fn env ->
          # Record that we entered the scope
          Agent.update(agent, fn log -> [:entered | log] end)

          finally_k = fn result, e ->
            # Record cleanup with the result type
            Agent.update(agent, fn log -> [{:cleanup, result.__struct__} | log] end)
            {result, e}
          end

          {env, finally_k}
        end)
        |> Yield.with_handler()

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :cleanup_test)

      assert_receive {AsyncCoroutine, :cleanup_test, %ExternalSuspend{value: :waiting}}

      # Verify we entered the scope
      assert Agent.get(agent, & &1) == [:entered]

      # Cancel - should trigger cleanup
      AsyncCoroutine.cancel(runner)

      assert_receive {AsyncCoroutine, :cleanup_test, %Cancelled{reason: :cancelled}}

      # Verify cleanup was called with Cancelled
      log = Agent.get(agent, & &1)
      assert log == [{:cleanup, Cancelled}, :entered]

      Agent.stop(agent)
    end
  end

  describe "cancel_sync/2" do
    test "cancels and waits for completion" do
      computation =
        comp do
          _ <- Yield.yield(:waiting)
          :completed
        end

      {:ok, runner, %ExternalSuspend{value: :waiting}} =
        AsyncCoroutine.run_sync(computation, tag: :cancel_sync_test)

      # Cancel synchronously
      assert %Cancelled{reason: :cancelled} = AsyncCoroutine.cancel_sync(runner)

      # No additional messages should arrive
      refute_receive {AsyncCoroutine, :cancel_sync_test, _}, 10
    end

    test "cancel_sync invokes leave_scope for cleanup" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      computation =
        Yield.yield(:waiting)
        |> Skuld.Comp.scoped(fn env ->
          Agent.update(agent, fn log -> [:entered | log] end)

          finally_k = fn result, e ->
            Agent.update(agent, fn log -> [{:cleanup, result.__struct__} | log] end)
            {result, e}
          end

          {env, finally_k}
        end)
        |> Yield.with_handler()

      {:ok, runner, %ExternalSuspend{value: :waiting}} =
        AsyncCoroutine.run_sync(computation, tag: :cleanup_sync)

      # Verify we entered the scope
      assert Agent.get(agent, & &1) == [:entered]

      # Cancel synchronously - should trigger cleanup
      assert %Cancelled{reason: :cancelled} = AsyncCoroutine.cancel_sync(runner)

      # Verify cleanup was called with Cancelled
      log = Agent.get(agent, & &1)
      assert log == [{:cleanup, Cancelled}, :entered]

      Agent.stop(agent)
    end

    test "cancel_sync can be called from different process than caller" do
      computation =
        comp do
          _ <- Yield.yield(:waiting)
          :completed
        end

      # Start with self() as caller
      {:ok, runner, %ExternalSuspend{value: :waiting}} =
        AsyncCoroutine.run_sync(computation, tag: :cross_process)

      # Cancel from a different process
      test_pid = self()

      spawn(fn ->
        result = AsyncCoroutine.cancel_sync(runner)
        send(test_pid, {:cancel_result, result})
      end)

      # The spawned process should get the result
      assert_receive {:cancel_result, %Cancelled{reason: :cancelled}}

      # Original caller should NOT receive anything (the spawned process got it)
      refute_receive {AsyncCoroutine, :cross_process, _}, 50
    end

    test "cancel_sync respects timeout" do
      computation =
        comp do
          _ <- Yield.yield(:waiting)
          :completed
        end

      {:ok, runner, %ExternalSuspend{value: :waiting}} =
        AsyncCoroutine.run_sync(computation, tag: :timeout_test)

      # This should complete quickly, well within timeout
      assert %Cancelled{reason: :cancelled} =
               AsyncCoroutine.cancel_sync(runner, timeout: 1000)
    end
  end

  describe "process lifecycle" do
    test "runner process exits after sending result" do
      computation = comp(do: :done)

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :lifecycle)

      assert_receive {AsyncCoroutine, :lifecycle, :done}

      # Wait for process to exit via monitor (already set up in start/2)
      # :noproc means process already exited before monitor was set up (fast exit)
      assert_receive {:DOWN, _, :process, pid, reason}
                     when pid == runner.pid and reason in [:normal, :noproc]
    end

    test "exceptions in computation become throw messages" do
      # Skuld converts exceptions to Throws, so they come back as messages
      computation = fn _env, _k -> raise "something went wrong" end

      {:ok, _runner} = AsyncCoroutine.run(computation, tag: :raising)

      # Should receive a throw message with the exception info
      assert_receive {AsyncCoroutine, :raising,
                      %ThrowStruct{
                        error: %{
                          kind: :error,
                          payload: %RuntimeError{message: "something went wrong"}
                        }
                      }}
    end

    test "runner exits normally after sending throw message" do
      computation = fn _env, _k -> raise "boom" end

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :exits_normally)

      assert_receive {AsyncCoroutine, :exits_normally, %ThrowStruct{}}

      # Wait for process to exit normally via monitor
      # :noproc means process already exited before monitor was set up (fast exit)
      assert_receive {:DOWN, _, :process, pid, reason}
                     when pid == runner.pid and reason in [:normal, :noproc]
    end
  end

  describe "transform_suspend" do
    test "applies transform_suspend on initial yield" do
      # A computation with a scoped effect that decorates suspends
      computation =
        comp do
          _ <- Yield.yield(:first)
          :done
        end
        |> Skuld.Comp.with_scoped_state(:counter, 1,
          suspend: fn suspend, env ->
            counter = Skuld.Comp.Env.get_state(env, :counter)
            data = suspend.data || %{}
            {%{suspend | data: Map.put(data, :counter, counter)}, env}
          end
        )

      {:ok, runner, %ExternalSuspend{value: :first, data: data}} =
        AsyncCoroutine.run_sync(computation, tag: :transform_initial)

      # Initial suspend should have the data from transform_suspend
      assert data[:counter] == 1

      assert :done = AsyncCoroutine.run_sync(runner, :ok)
    end

    test "applies transform_suspend on subsequent yields after resume" do
      # This is the key test for the fix - transform_suspend must be applied
      # not just on the initial yield, but also on subsequent yields after resume.
      # We use a simple counter that increments on each yield.
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      computation =
        comp do
          _ <- Yield.yield(:first)
          _ <- Yield.yield(:second)
          _ <- Yield.yield(:third)
          :done
        end
        |> Skuld.Comp.scoped(fn env ->
          # Set up transform_suspend that captures an incrementing counter
          old_transform = Skuld.Comp.Env.get_transform_suspend(env)

          new_transform = fn suspend, e ->
            {suspend1, e1} = old_transform.(suspend, e)
            # Increment counter and add to data
            counter = Agent.get_and_update(agent, fn c -> {c + 1, c + 1} end)
            data = suspend1.data || %{}
            {%{suspend1 | data: Map.put(data, :yield_count, counter)}, e1}
          end

          {Skuld.Comp.Env.with_transform_suspend(env, new_transform),
           fn value, e -> {value, e} end}
        end)

      {:ok, runner, %ExternalSuspend{value: :first, data: data1}} =
        AsyncCoroutine.run_sync(computation, tag: :transform_subsequent)

      # First yield - counter should be 1
      assert data1[:yield_count] == 1

      # Resume and get second yield
      %ExternalSuspend{value: :second, data: data2} = AsyncCoroutine.run_sync(runner, :ok)

      # Second yield - counter should be 2 (transform_suspend was applied on resume!)
      assert data2[:yield_count] == 2

      # Resume and get third yield
      %ExternalSuspend{value: :third, data: data3} = AsyncCoroutine.run_sync(runner, :ok)

      # Third yield - counter should be 3
      assert data3[:yield_count] == 3

      assert :done = AsyncCoroutine.run_sync(runner, :ok)

      Agent.stop(agent)
    end
  end

  describe "integration scenarios" do
    test "simulates LiveView-style interaction" do
      # A computation that simulates a multi-step wizard
      wizard =
        comp do
          name <- Yield.yield(%{step: 1, prompt: "Enter name"})
          email <- Yield.yield(%{step: 2, prompt: "Enter email"})
          %{name: name, email: email}
        end

      {:ok, runner} = AsyncCoroutine.run(wizard, tag: :wizard)

      # Step 1
      assert_receive {AsyncCoroutine, :wizard,
                      %ExternalSuspend{value: %{step: 1, prompt: "Enter name"}}}

      AsyncCoroutine.run(runner, "Alice")

      # Step 2
      assert_receive {AsyncCoroutine, :wizard,
                      %ExternalSuspend{value: %{step: 2, prompt: "Enter email"}}}

      AsyncCoroutine.run(runner, "alice@example.com")

      # Result
      assert_receive {AsyncCoroutine, :wizard, %{name: "Alice", email: "alice@example.com"}}
    end

    test "computation with effects and yields" do
      computation =
        comp do
          base <- Reader.ask()
          multiplier <- Yield.yield(:get_multiplier)
          base * multiplier
        end
        |> Reader.with_handler(21)

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :mixed)

      assert_receive {AsyncCoroutine, :mixed, %ExternalSuspend{value: :get_multiplier}}
      AsyncCoroutine.run(runner, 2)

      assert_receive {AsyncCoroutine, :mixed, 42}
    end
  end
end
