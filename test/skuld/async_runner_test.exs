defmodule Skuld.AsyncRunnerTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.AsyncRunner
  alias Skuld.Effects.{State, Reader, Throw, Yield}

  describe "start/2" do
    test "runs a simple computation and sends result" do
      computation =
        comp do
          return({:ok, 42})
        end

      {:ok, _runner} = AsyncRunner.start(computation, tag: :test)

      assert_receive {:test, :result, {:ok, 42}}
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

      {:ok, _runner} = AsyncRunner.start(computation, tag: :with_effects)

      assert_receive {:with_effects, :result, 42}
    end

    test "sends throw errors" do
      computation =
        comp do
          _ <- Throw.throw(:something_went_wrong)
          return(:never_reached)
        end

      {:ok, _runner} = AsyncRunner.start(computation, tag: :throwing)

      assert_receive {:throwing, :throw, :something_went_wrong}
    end

    test "sends yields and waits for resume" do
      computation =
        comp do
          x <- Yield.yield(:first)
          y <- Yield.yield(:second)
          return(x + y)
        end

      {:ok, runner} = AsyncRunner.start(computation, tag: :yielding)

      # First yield
      assert_receive {:yielding, :yield, :first}
      AsyncRunner.resume(runner, 10)

      # Second yield
      assert_receive {:yielding, :yield, :second}
      AsyncRunner.resume(runner, 32)

      # Final result
      assert_receive {:yielding, :result, 42}
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

      {:ok, _runner} = AsyncRunner.start(computation, tag: :custom_caller, caller: middleman)

      assert_receive {:forwarded, {:custom_caller, :result, :hello}}
    end
  end

  describe "start_sync/2" do
    test "returns first yield synchronously" do
      computation =
        comp do
          x <- Yield.yield(:ready)
          return(x * 2)
        end

      {:ok, runner, {:yield, :ready}} = AsyncRunner.start_sync(computation, tag: :sync_start)

      # Can continue with resume_sync
      assert {:result, 42} = AsyncRunner.resume_sync(runner, 21)
    end

    test "returns result when computation completes immediately" do
      computation = comp(do: return({:ok, 42}))

      {:ok, _runner, {:result, {:ok, 42}}} =
        AsyncRunner.start_sync(computation, tag: :immediate_result)
    end

    test "returns throw when computation throws immediately" do
      computation =
        comp do
          _ <- Throw.throw(:immediate_error)
          return(:never)
        end

      {:ok, _runner, {:throw, :immediate_error}} =
        AsyncRunner.start_sync(computation, tag: :immediate_throw)
    end

    test "works with effects" do
      computation =
        comp do
          base <- Reader.ask()
          multiplier <- Yield.yield(:get_multiplier)
          return(base * multiplier)
        end
        |> Reader.with_handler(21)

      {:ok, runner, {:yield, :get_multiplier}} =
        AsyncRunner.start_sync(computation, tag: :with_effects)

      assert {:result, 42} = AsyncRunner.resume_sync(runner, 2)
    end

    test "respects custom timeout" do
      computation =
        comp do
          x <- Yield.yield(:first)
          return(x)
        end

      # Should succeed quickly with reasonable timeout
      {:ok, runner, {:yield, :first}} =
        AsyncRunner.start_sync(computation, tag: :custom_timeout, timeout: 1000)

      assert {:result, :done} = AsyncRunner.resume_sync(runner, :done)
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
      {:ok, runner, {:yield, :ready}} = AsyncRunner.start_sync(processor, tag: :processor)

      # Send first command, get back ready with result
      {:yield, {:ready, {:processed, :cmd_a}}} = AsyncRunner.resume_sync(runner, :cmd_a)

      # Send second command, get final result
      {:result, {:done, {:processed, :cmd_a}, {:processed, :cmd_b}}} =
        AsyncRunner.resume_sync(runner, :cmd_b)
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

      {:ok, runner} = AsyncRunner.start(computation, tag: :sync_yield)

      # First yield comes via message
      assert_receive {:sync_yield, :yield, :first}

      # Resume sync and wait for second yield
      assert {:yield, :second} = AsyncRunner.resume_sync(runner, 10)

      # Resume sync and wait for result
      assert {:result, 42} = AsyncRunner.resume_sync(runner, 32)
    end

    test "returns result when computation completes" do
      computation =
        comp do
          x <- Yield.yield(:get_value)
          return({:ok, x * 2})
        end

      {:ok, runner} = AsyncRunner.start(computation, tag: :sync_result)

      assert_receive {:sync_result, :yield, :get_value}
      assert {:result, {:ok, 42}} = AsyncRunner.resume_sync(runner, 21)
    end

    test "returns throw on error" do
      computation =
        comp do
          x <- Yield.yield(:get_value)
          _ <- if x < 0, do: Throw.throw(:negative)
          return(x)
        end

      {:ok, runner} = AsyncRunner.start(computation, tag: :sync_throw)

      assert_receive {:sync_throw, :yield, :get_value}
      assert {:throw, :negative} = AsyncRunner.resume_sync(runner, -5)
    end

    test "respects custom timeout" do
      # Create a computation where we can control timing
      computation =
        comp do
          _ <- Yield.yield(:ready)
          return(:done)
        end

      {:ok, runner} = AsyncRunner.start(computation, tag: :custom_timeout)

      assert_receive {:custom_timeout, :yield, :ready}

      # This should succeed quickly
      assert {:result, :done} = AsyncRunner.resume_sync(runner, :go, timeout: 1000)
    end

    test "mixed sync and async resumes" do
      computation =
        comp do
          a <- Yield.yield(:a)
          b <- Yield.yield(:b)
          c <- Yield.yield(:c)
          return(a + b + c)
        end

      {:ok, runner} = AsyncRunner.start(computation, tag: :mixed)

      # First yield via message
      assert_receive {:mixed, :yield, :a}

      # Async resume
      AsyncRunner.resume(runner, 1)
      assert_receive {:mixed, :yield, :b}

      # Sync resume
      assert {:yield, :c} = AsyncRunner.resume_sync(runner, 2)

      # Sync resume to completion
      assert {:result, 6} = AsyncRunner.resume_sync(runner, 3)
    end
  end

  describe "cancel/1" do
    test "cancels a yielded computation" do
      computation =
        comp do
          _ <- Yield.yield(:waiting)
          return(:completed)
        end

      {:ok, runner} = AsyncRunner.start(computation, tag: :cancellable)

      assert_receive {:cancellable, :yield, :waiting}

      AsyncRunner.cancel(runner)

      assert_receive {:cancellable, :stopped, :cancelled}
      refute_receive {:cancellable, :result, _}, 10
    end
  end

  describe "process lifecycle" do
    test "runner process exits after sending result" do
      computation = comp(do: return(:done))

      {:ok, runner} = AsyncRunner.start(computation, tag: :lifecycle)

      assert_receive {:lifecycle, :result, :done}

      # Wait for process to exit via monitor (already set up in start/2)
      # :noproc means process already exited before monitor was set up (fast exit)
      assert_receive {:DOWN, _, :process, pid, reason}
                     when pid == runner.pid and reason in [:normal, :noproc]
    end

    test "exceptions in computation become throw messages" do
      # Skuld converts exceptions to Throws, so they come back as messages
      computation = fn _env, _k -> raise "something went wrong" end

      {:ok, _runner} = AsyncRunner.start(computation, tag: :raising)

      # Should receive a throw message with the exception info
      assert_receive {:raising, :throw,
                      %{kind: :error, payload: %RuntimeError{message: "something went wrong"}}}
    end

    test "runner exits normally after sending throw message" do
      computation = fn _env, _k -> raise "boom" end

      {:ok, runner} = AsyncRunner.start(computation, tag: :exits_normally)

      assert_receive {:exits_normally, :throw, _error}

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

      {:ok, runner} = AsyncRunner.start(wizard, tag: :wizard)

      # Step 1
      assert_receive {:wizard, :yield, %{step: 1, prompt: "Enter name"}}
      AsyncRunner.resume(runner, "Alice")

      # Step 2
      assert_receive {:wizard, :yield, %{step: 2, prompt: "Enter email"}}
      AsyncRunner.resume(runner, "alice@example.com")

      # Result
      assert_receive {:wizard, :result, %{name: "Alice", email: "alice@example.com"}}
    end

    test "computation with effects and yields" do
      computation =
        comp do
          base <- Reader.ask()
          multiplier <- Yield.yield(:get_multiplier)
          return(base * multiplier)
        end
        |> Reader.with_handler(21)

      {:ok, runner} = AsyncRunner.start(computation, tag: :mixed)

      assert_receive {:mixed, :yield, :get_multiplier}
      AsyncRunner.resume(runner, 2)

      assert_receive {:mixed, :result, 42}
    end
  end
end
