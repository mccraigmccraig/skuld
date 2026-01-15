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
      refute_receive {:cancellable, :result, _}
    end
  end

  describe "process lifecycle" do
    test "runner process exits after sending result" do
      computation = comp(do: return(:done))

      {:ok, runner} = AsyncRunner.start(computation, tag: :lifecycle)

      assert_receive {:lifecycle, :result, :done}

      # Give process time to exit
      Process.sleep(10)
      refute Process.alive?(runner.pid)
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

      # Runner should exit normally (not crash)
      Process.sleep(10)
      refute Process.alive?(runner.pid)
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
