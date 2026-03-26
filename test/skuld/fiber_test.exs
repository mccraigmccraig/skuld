defmodule Skuld.FiberTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Fiber
  alias Skuld.Fiber.Handle
  alias Skuld.Effects.Yield
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  describe "Fiber.new/2" do
    test "creates a pending fiber" do
      env = Env.new()
      comp = Comp.pure(42)

      fiber = Fiber.new(comp, env)

      assert fiber.status == :pending
      assert fiber.computation == comp
      assert fiber.env == env
      assert is_reference(fiber.id)
      assert fiber.suspended_k == nil
    end

    test "each fiber has unique id" do
      env = Env.new()
      comp = Comp.pure(42)

      fiber1 = Fiber.new(comp, env)
      fiber2 = Fiber.new(comp, env)

      refute fiber1.id == fiber2.id
    end
  end

  describe "Fiber.run_until_suspend/1" do
    test "pure computation completes immediately" do
      env = Env.new()
      fiber = Fiber.new(Comp.pure(42), env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :completed
      assert fiber.result == 42
      assert fiber.env != nil
    end

    test "effectful computation completes" do
      comp =
        comp do
          x <- State.get()
          _ <- State.put(x + 10)
          y <- State.get()
          {x, y}
        end
        |> State.with_handler(5)

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :completed
      assert fiber.result == {5, 15}
    end

    test "yielding computation suspends" do
      comp =
        comp do
          x <- Yield.yield(:get_value)
          x * 2
        end
        |> Yield.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :suspended
      assert is_function(fiber.suspended_k, 2)
      assert fiber.env != nil
      assert fiber.internal_suspend == nil
    end

    test "throws return error" do
      comp =
        comp do
          _ <- Throw.throw(:my_error)
          :should_not_reach
        end
        |> Throw.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :error
      assert fiber.error == {:throw, :my_error}
      assert fiber.env != nil
    end

    test "elixir raise returns error" do
      comp = fn _env, _k ->
        raise "boom"
      end

      env = Env.new()
      fiber = Fiber.new(comp, env)

      # Comp.call converts exceptions to Throw effects with a map containing
      # :kind, :payload, :stacktrace - which then becomes {:throw, map} error
      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :error
      assert {:throw, %{kind: :error, payload: %RuntimeError{message: "boom"}}} = fiber.error
      assert fiber.env != nil
    end

    test "cannot run non-pending fiber" do
      env = Env.new()
      fiber = Fiber.new(Comp.pure(42), env)

      %Fiber{status: :completed} = Fiber.run_until_suspend(fiber)

      # Make a new fiber and manually set status
      suspended_fiber = %{fiber | status: :suspended}

      assert_raise ArgumentError, ~r/Cannot run fiber in suspended status/, fn ->
        Fiber.run_until_suspend(suspended_fiber)
      end
    end
  end

  describe "Fiber.resume/2" do
    test "resumes suspended fiber to completion" do
      comp =
        comp do
          x <- Yield.yield(:get_value)
          x * 2
        end
        |> Yield.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :suspended

      fiber = Fiber.resume(fiber, 21)
      assert fiber.status == :completed
      assert fiber.result == 42
    end

    test "resumes to another suspension" do
      comp =
        comp do
          x <- Yield.yield(:first)
          y <- Yield.yield(:second)
          x + y
        end
        |> Yield.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :suspended

      fiber = Fiber.resume(fiber, 10)
      assert fiber.status == :suspended

      fiber = Fiber.resume(fiber, 20)
      assert fiber.status == :completed
      assert fiber.result == 30
    end

    test "resume can error" do
      comp =
        comp do
          x <- Yield.yield(:get_value)

          if x == :trigger_error do
            Throw.throw(:triggered)
          else
            Comp.pure(x)
          end
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :suspended

      fiber = Fiber.resume(fiber, :trigger_error)
      assert fiber.status == :error
      assert fiber.error == {:throw, :triggered}
    end

    test "cannot resume non-suspended fiber" do
      env = Env.new()
      fiber = Fiber.new(Comp.pure(42), env)

      assert_raise ArgumentError, ~r/Cannot resume fiber in pending status/, fn ->
        Fiber.resume(fiber, :value)
      end
    end
  end

  describe "Fiber.cancel/1" do
    test "cancels pending fiber without leave_scope (no scopes entered)" do
      env = Env.new()
      fiber = Fiber.new(Comp.pure(42), env)

      cancelled = Fiber.cancel(fiber)

      assert cancelled.status == :cancelled
      assert cancelled.computation == nil
      assert cancelled.suspended_k == nil
      assert cancelled.internal_suspend == nil
      assert cancelled.env == nil
      assert cancelled.result == nil
      assert cancelled.error == nil
    end

    test "cancels suspended fiber and invokes leave_scope" do
      test_pid = self()

      comp =
        Yield.yield(:waiting)
        |> Comp.scoped(fn env ->
          finally_k = fn result, e ->
            send(test_pid, {:cleanup_called, result})
            {result, e}
          end

          {env, finally_k}
        end)
        |> Yield.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :suspended

      cancelled = Fiber.cancel(fiber)

      assert cancelled.status == :cancelled
      assert cancelled.suspended_k == nil
      assert cancelled.internal_suspend == nil
      # env is preserved after leave_scope runs
      assert cancelled.env != nil

      # leave_scope was invoked with a Cancelled sentinel
      assert_received {:cleanup_called, %Comp.Cancelled{reason: :cancelled}}
    end

    test "cancel with custom reason" do
      test_pid = self()

      comp =
        Yield.yield(:waiting)
        |> Comp.scoped(fn env ->
          finally_k = fn result, e ->
            send(test_pid, {:cleanup_reason, result})
            {result, e}
          end

          {env, finally_k}
        end)
        |> Yield.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      cancelled = Fiber.cancel(fiber, :timeout)

      assert cancelled.status == :cancelled
      assert_received {:cleanup_reason, %Comp.Cancelled{reason: :timeout}}
    end

    test "nested scopes all get cleanup on cancel" do
      test_pid = self()

      inner =
        Yield.yield(:waiting)
        |> Comp.scoped(fn env ->
          finally_k = fn result, e ->
            send(test_pid, {:inner_cleanup, result})
            {result, e}
          end

          {env, finally_k}
        end)

      comp =
        inner
        |> Comp.scoped(fn env ->
          finally_k = fn result, e ->
            send(test_pid, {:outer_cleanup, result})
            {result, e}
          end

          {env, finally_k}
        end)
        |> Yield.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :suspended

      _cancelled = Fiber.cancel(fiber, :shutdown)

      # Both scopes cleaned up with the Cancelled sentinel
      assert_received {:inner_cleanup, %Comp.Cancelled{reason: :shutdown}}
      assert_received {:outer_cleanup, %Comp.Cancelled{reason: :shutdown}}
    end

    test "State handler cleans up on cancel" do
      comp =
        Comp.bind(State.put(42), fn _ ->
          Yield.yield(:waiting)
        end)
        |> State.with_handler(0)
        |> Yield.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :suspended

      cancelled = Fiber.cancel(fiber)

      assert cancelled.status == :cancelled
      # State handler's scoped cleanup should have removed its state key
      assert Env.get_state(cancelled.env, State.state_key(State)) == nil
    end

    test "cancel without leave_scope (simple suspend, no scoped effects)" do
      comp = Yield.yield(:value) |> Yield.with_handler()
      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :suspended

      cancelled = Fiber.cancel(fiber)

      assert cancelled.status == :cancelled
      assert cancelled.suspended_k == nil
      assert cancelled.internal_suspend == nil
      # env is preserved (leave_scope identity ran successfully)
      assert cancelled.env != nil
    end

    test "cancel is no-op on completed fiber" do
      env = Env.new()
      fiber = Fiber.new(Comp.pure(42), env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :completed
      assert fiber.result == 42

      same = Fiber.cancel(fiber)
      assert same.status == :completed
      assert same.result == 42
      assert same == fiber
    end

    test "cancel is no-op on errored fiber" do
      comp =
        comp do
          _ <- Throw.throw(:boom)
          :unreachable
        end
        |> Throw.with_handler()

      env = Env.new()
      fiber = Fiber.new(comp, env)

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :error
      assert fiber.error == {:throw, :boom}

      same = Fiber.cancel(fiber)
      assert same.status == :error
      assert same.error == {:throw, :boom}
      assert same == fiber
    end

    test "cancel is no-op on already-cancelled fiber" do
      env = Env.new()
      fiber = Fiber.new(Comp.pure(42), env)

      cancelled = Fiber.cancel(fiber)
      assert cancelled.status == :cancelled

      same = Fiber.cancel(cancelled, :different_reason)
      assert same.status == :cancelled
      assert same == cancelled
    end
  end

  describe "Fiber.terminal?/1" do
    test "pending is not terminal" do
      fiber = Fiber.new(Comp.pure(42), Env.new())
      refute Fiber.terminal?(fiber)
    end

    test "suspended is not terminal" do
      comp = Yield.yield(:value) |> Yield.with_handler()
      fiber = Fiber.new(comp, Env.new())

      fiber = Fiber.run_until_suspend(fiber)
      assert fiber.status == :suspended
      refute Fiber.terminal?(fiber)
    end

    test "cancelled is terminal" do
      fiber = Fiber.new(Comp.pure(42), Env.new())
      cancelled = Fiber.cancel(fiber)
      assert Fiber.terminal?(cancelled)
    end
  end

  describe "Handle" do
    test "creates handle with ids" do
      fiber_id = make_ref()
      pool_id = make_ref()

      handle = Handle.new(fiber_id, pool_id)

      assert Handle.fiber_id(handle) == fiber_id
      assert Handle.pool_id(handle) == pool_id
    end

    test "handles are equal if ids match" do
      fiber_id = make_ref()
      pool_id = make_ref()

      handle1 = Handle.new(fiber_id, pool_id)
      handle2 = Handle.new(fiber_id, pool_id)

      assert handle1 == handle2
    end

    test "handles can be used as map keys" do
      handle = Handle.new(make_ref(), make_ref())

      map = %{handle => :value}
      assert Map.get(map, handle) == :value
    end
  end
end
