defmodule Skuld.AsyncComputationTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.AsyncComputation
  alias Skuld.Comp.Cancelled
  alias Skuld.Comp.Suspend
  alias Skuld.Comp.Throw, as: ThrowStruct
  alias Skuld.Effects.Reader
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield

  describe "start/2" do
    test "runs a simple computation and sends result" do
      computation =
        comp do
          return({:ok, 42})
        end

      {:ok, _runner} = AsyncComputation.start(computation, tag: :test)

      assert_receive {AsyncComputation, :test, {:ok, 42}}
    end

    test "computation can use effects" do
      computation =
        comp do
          x <- Reader.ask()
          y <- State.get()
          return(x + y)
        end
        |> Reader.with_handler(10)
        |> State.with_handler(32)

      {:ok, _runner} = AsyncComputation.start(computation, tag: :with_effects)

      assert_receive {AsyncComputation, :with_effects, 42}
    end

    test "sends throw errors" do
      computation =
        comp do
          _ <- Throw.throw(:something_went_wrong)
          return(:never_reached)
        end

      {:ok, _runner} = AsyncComputation.start(computation, tag: :throwing)

      assert_receive {AsyncComputation, :throwing, %ThrowStruct{error: :something_went_wrong}}
    end

    test "sends yields and waits for resume" do
      computation =
        comp do
          x <- Yield.yield(:first)
          y <- Yield.yield(:second)
          return(x + y)
        end

      {:ok, runner} = AsyncComputation.start(computation, tag: :yielding)

      # First yield (data is nil since no scoped effects with suspend decoration)
      assert_receive {AsyncComputation, :yielding, %Suspend{value: :first}}
      AsyncComputation.resume(runner, 10)

      # Second yield
      assert_receive {AsyncComputation, :yielding, %Suspend{value: :second}}
      AsyncComputation.resume(runner, 32)

      # Final result
      assert_receive {AsyncComputation, :yielding, 42}
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

      computation = comp(do: return(:hello))

      {:ok, _runner} = AsyncComputation.start(computation, tag: :custom_caller, caller: middleman)

      assert_receive {:forwarded, {AsyncComputation, :custom_caller, :hello}}
    end
  end

  describe "start_sync/2" do
    test "returns first yield synchronously" do
      computation =
        comp do
          x <- Yield.yield(:ready)
          return(x * 2)
        end

      {:ok, runner, %Suspend{value: :ready}} =
        AsyncComputation.start_sync(computation, tag: :sync_start)

      # Can continue with resume_sync
      assert 42 = AsyncComputation.resume_sync(runner, 21)
    end

    test "returns result when computation completes immediately" do
      computation = comp(do: return({:ok, 42}))

      {:ok, _runner, {:ok, 42}} =
        AsyncComputation.start_sync(computation, tag: :immediate_result)
    end

    test "returns throw when computation throws immediately" do
      computation =
        comp do
          _ <- Throw.throw(:immediate_error)
          return(:never)
        end

      {:ok, _runner, %ThrowStruct{error: :immediate_error}} =
        AsyncComputation.start_sync(computation, tag: :immediate_throw)
    end

    test "works with effects" do
      computation =
        comp do
          base <- Reader.ask()
          multiplier <- Yield.yield(:get_multiplier)
          return(base * multiplier)
        end
        |> Reader.with_handler(21)

      {:ok, runner, %Suspend{value: :get_multiplier}} =
        AsyncComputation.start_sync(computation, tag: :with_effects)

      assert 42 = AsyncComputation.resume_sync(runner, 2)
    end

    test "respects custom timeout" do
      computation =
        comp do
          x <- Yield.yield(:first)
          return(x)
        end

      # Should succeed quickly with reasonable timeout
      {:ok, runner, %Suspend{value: :first}} =
        AsyncComputation.start_sync(computation, tag: :custom_timeout, timeout: 1000)

      assert :done = AsyncComputation.resume_sync(runner, :done)
    end

    test "command processor pattern - sync start then sync resume loop" do
      # Simulates a command processor that yields ready, processes commands, yields ready again
      processor =
        comp do
          cmd1 <- Yield.yield(:ready)
          result1 = {:processed, cmd1}
          cmd2 <- Yield.yield({:ready, result1})
          result2 = {:processed, cmd2}
          return({:done, result1, result2})
        end

      # Start sync - get first :ready yield
      {:ok, runner, %Suspend{value: :ready}} =
        AsyncComputation.start_sync(processor, tag: :processor)

      # Send first command, get back ready with result
      %Suspend{value: {:ready, {:processed, :cmd_a}}} =
        AsyncComputation.resume_sync(runner, :cmd_a)

      # Send second command, get final result
      {:done, {:processed, :cmd_a}, {:processed, :cmd_b}} =
        AsyncComputation.resume_sync(runner, :cmd_b)
    end
  end

  describe "resume_sync/3" do
    test "waits for next yield" do
      computation =
        comp do
          x <- Yield.yield(:first)
          y <- Yield.yield(:second)
          return(x + y)
        end

      {:ok, runner} = AsyncComputation.start(computation, tag: :sync_yield)

      # First yield comes via message
      assert_receive {AsyncComputation, :sync_yield, %Suspend{value: :first}}

      # Resume sync and wait for second yield
      assert %Suspend{value: :second} = AsyncComputation.resume_sync(runner, 10)

      # Resume sync and wait for result
      assert 42 = AsyncComputation.resume_sync(runner, 32)
    end

    test "returns result when computation completes" do
      computation =
        comp do
          x <- Yield.yield(:get_value)
          return({:ok, x * 2})
        end

      {:ok, runner} = AsyncComputation.start(computation, tag: :sync_result)

      assert_receive {AsyncComputation, :sync_result, %Suspend{value: :get_value}}
      assert {:ok, 42} = AsyncComputation.resume_sync(runner, 21)
    end

    test "returns throw on error" do
      computation =
        comp do
          x <- Yield.yield(:get_value)
          _ <- if x < 0, do: Throw.throw(:negative)
          return(x)
        end

      {:ok, runner} = AsyncComputation.start(computation, tag: :sync_throw)

      assert_receive {AsyncComputation, :sync_throw, %Suspend{value: :get_value}}
      assert %ThrowStruct{error: :negative} = AsyncComputation.resume_sync(runner, -5)
    end

    test "respects custom timeout" do
      # Create a computation where we can control timing
      computation =
        comp do
          _ <- Yield.yield(:ready)
          return(:done)
        end

      {:ok, runner} = AsyncComputation.start(computation, tag: :custom_timeout)

      assert_receive {AsyncComputation, :custom_timeout, %Suspend{value: :ready}}

      # This should succeed quickly
      assert :done = AsyncComputation.resume_sync(runner, :go, timeout: 1000)
    end

    test "mixed sync and async resumes" do
      computation =
        comp do
          a <- Yield.yield(:a)
          b <- Yield.yield(:b)
          c <- Yield.yield(:c)
          return(a + b + c)
        end

      {:ok, runner} = AsyncComputation.start(computation, tag: :mixed)

      # First yield via message
      assert_receive {AsyncComputation, :mixed, %Suspend{value: :a}}

      # Async resume
      AsyncComputation.resume(runner, 1)
      assert_receive {AsyncComputation, :mixed, %Suspend{value: :b}}

      # Sync resume
      assert %Suspend{value: :c} = AsyncComputation.resume_sync(runner, 2)

      # Sync resume to completion
      assert 6 = AsyncComputation.resume_sync(runner, 3)
    end
  end

  describe "cancel/1" do
    test "cancels a yielded computation" do
      computation =
        comp do
          _ <- Yield.yield(:waiting)
          return(:completed)
        end

      {:ok, runner} = AsyncComputation.start(computation, tag: :cancellable)

      assert_receive {AsyncComputation, :cancellable, %Suspend{value: :waiting}}

      AsyncComputation.cancel(runner)

      assert_receive {AsyncComputation, :cancellable, %Cancelled{reason: :cancelled}}
      refute_receive {AsyncComputation, :cancellable, _}, 10
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

      {:ok, runner} = AsyncComputation.start(computation, tag: :cleanup_test)

      assert_receive {AsyncComputation, :cleanup_test, %Suspend{value: :waiting}}

      # Verify we entered the scope
      assert Agent.get(agent, & &1) == [:entered]

      # Cancel - should trigger cleanup
      AsyncComputation.cancel(runner)

      assert_receive {AsyncComputation, :cleanup_test, %Cancelled{reason: :cancelled}}

      # Verify cleanup was called with Cancelled
      log = Agent.get(agent, & &1)
      assert log == [{:cleanup, Cancelled}, :entered]

      Agent.stop(agent)
    end
  end

  describe "process lifecycle" do
    test "runner process exits after sending result" do
      computation = comp(do: return(:done))

      {:ok, runner} = AsyncComputation.start(computation, tag: :lifecycle)

      assert_receive {AsyncComputation, :lifecycle, :done}

      # Wait for process to exit via monitor (already set up in start/2)
      # :noproc means process already exited before monitor was set up (fast exit)
      assert_receive {:DOWN, _, :process, pid, reason}
                     when pid == runner.pid and reason in [:normal, :noproc]
    end

    test "exceptions in computation become throw messages" do
      # Skuld converts exceptions to Throws, so they come back as messages
      computation = fn _env, _k -> raise "something went wrong" end

      {:ok, _runner} = AsyncComputation.start(computation, tag: :raising)

      # Should receive a throw message with the exception info
      assert_receive {AsyncComputation, :raising,
                      %ThrowStruct{
                        error: %{
                          kind: :error,
                          payload: %RuntimeError{message: "something went wrong"}
                        }
                      }}
    end

    test "runner exits normally after sending throw message" do
      computation = fn _env, _k -> raise "boom" end

      {:ok, runner} = AsyncComputation.start(computation, tag: :exits_normally)

      assert_receive {AsyncComputation, :exits_normally, %ThrowStruct{}}

      # Wait for process to exit normally via monitor
      # :noproc means process already exited before monitor was set up (fast exit)
      assert_receive {:DOWN, _, :process, pid, reason}
                     when pid == runner.pid and reason in [:normal, :noproc]
    end
  end

  describe "integration scenarios" do
    test "simulates LiveView-style interaction" do
      # A computation that simulates a multi-step wizard
      wizard =
        comp do
          name <- Yield.yield(%{step: 1, prompt: "Enter name"})
          email <- Yield.yield(%{step: 2, prompt: "Enter email"})
          return(%{name: name, email: email})
        end

      {:ok, runner} = AsyncComputation.start(wizard, tag: :wizard)

      # Step 1
      assert_receive {AsyncComputation, :wizard,
                      %Suspend{value: %{step: 1, prompt: "Enter name"}}}

      AsyncComputation.resume(runner, "Alice")

      # Step 2
      assert_receive {AsyncComputation, :wizard,
                      %Suspend{value: %{step: 2, prompt: "Enter email"}}}

      AsyncComputation.resume(runner, "alice@example.com")

      # Result
      assert_receive {AsyncComputation, :wizard, %{name: "Alice", email: "alice@example.com"}}
    end

    test "computation with effects and yields" do
      computation =
        comp do
          base <- Reader.ask()
          multiplier <- Yield.yield(:get_multiplier)
          return(base * multiplier)
        end
        |> Reader.with_handler(21)

      {:ok, runner} = AsyncComputation.start(computation, tag: :mixed)

      assert_receive {AsyncComputation, :mixed, %Suspend{value: :get_multiplier}}
      AsyncComputation.resume(runner, 2)

      assert_receive {AsyncComputation, :mixed, 42}
    end
  end
end
