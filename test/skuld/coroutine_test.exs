defmodule Skuld.CoroutineTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Coroutine
  alias Skuld.Coroutine.Cancelled
  alias Skuld.Coroutine.Completed
  alias Skuld.Coroutine.Error
  alias Skuld.Coroutine.Errored
  alias Skuld.Coroutine.ExternalSuspended
  alias Skuld.Coroutine.Pending
  alias Skuld.Coroutine.Handle
  alias Skuld.Effects.Yield
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  describe "Coroutine.new/2" do
    test "creates a pending fiber" do
      env = Env.new()
      comp = 42

      fiber = Coroutine.new(comp, env)

      assert match?(%Pending{}, fiber)
      assert fiber.computation == comp
      assert fiber.env == env
      assert is_reference(fiber.id)
    end

    test "each fiber has unique id" do
      env = Env.new()
      comp = 42

      fiber1 = Coroutine.new(comp, env)
      fiber2 = Coroutine.new(comp, env)

      refute fiber1.id == fiber2.id
    end
  end

  describe "Coroutine.run/1" do
    test "pure computation completes immediately" do
      env = Env.new()
      fiber = Coroutine.new(42, env)

      fiber = Coroutine.run(fiber)
      assert match?(%Completed{}, fiber)
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
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%Completed{}, fiber)
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
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%ExternalSuspended{}, fiber)
      assert fiber.value == :get_value
      assert is_function(fiber.k, 2)
      assert fiber.env != nil
    end

    test "throws return error" do
      comp =
        comp do
          _ <- Throw.throw(:my_error)
          :should_not_reach
        end
        |> Throw.with_handler()

      env = Env.new()
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%Errored{}, fiber)
      assert %Error{type: :throw, error: :my_error} = fiber.error
      assert fiber.env != nil
    end

    test "elixir raise returns error" do
      comp = fn _env, _k ->
        raise "boom"
      end

      env = Env.new()
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%Errored{}, fiber)
      assert %Error{type: :exception, error: %RuntimeError{message: "boom"}} = fiber.error
      assert fiber.env != nil
    end

    test "cannot run non-pending fiber" do
      env = Env.new()
      fiber = Coroutine.new(42, env)

      fiber = Coroutine.run(fiber)
      assert match?(%Completed{}, fiber)

      assert_raise ArgumentError, ~r/Cannot run fiber/, fn ->
        Coroutine.run(fiber)
      end
    end
  end

  describe "Coroutine.run/2" do
    test "resumes suspended fiber to completion" do
      comp =
        comp do
          x <- Yield.yield(:get_value)
          x * 2
        end
        |> Yield.with_handler()

      env = Env.new()
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%ExternalSuspended{}, fiber)

      fiber = Coroutine.run(fiber, 21)
      assert match?(%Completed{}, fiber)
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
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%ExternalSuspended{}, fiber)

      fiber = Coroutine.run(fiber, 10)
      assert match?(%ExternalSuspended{}, fiber)

      fiber = Coroutine.run(fiber, 20)
      assert match?(%Completed{}, fiber)
      assert fiber.result == 30
    end

    test "resume can error" do
      comp =
        comp do
          x <- Yield.yield(:get_value)

          if x == :trigger_error do
            Throw.throw(:triggered)
          else
            x
          end
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      env = Env.new()
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%ExternalSuspended{}, fiber)

      fiber = Coroutine.run(fiber, :trigger_error)
      assert match?(%Errored{}, fiber)
      assert %Error{type: :throw, error: :triggered} = fiber.error
    end

    test "cannot call run/2 on pending fiber" do
      env = Env.new()
      fiber = Coroutine.new(42, env)

      assert_raise ArgumentError, ~r/Cannot run fiber/, fn ->
        Coroutine.run(fiber, :value)
      end
    end
  end

  describe "Coroutine.cancel/1" do
    test "cancels pending fiber without leave_scope (no scopes entered)" do
      env = Env.new()
      fiber = Coroutine.new(42, env)

      cancelled = Coroutine.cancel(fiber)

      assert match?(%Cancelled{}, cancelled)
      assert cancelled.env == nil
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
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%ExternalSuspended{}, fiber)

      cancelled = Coroutine.cancel(fiber)

      assert match?(%Cancelled{}, cancelled)
      assert cancelled.env != nil

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
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      cancelled = Coroutine.cancel(fiber, :timeout)

      assert match?(%Cancelled{}, cancelled)
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
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%ExternalSuspended{}, fiber)

      _cancelled = Coroutine.cancel(fiber, :shutdown)

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
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%ExternalSuspended{}, fiber)

      cancelled = Coroutine.cancel(fiber)

      assert match?(%Cancelled{}, cancelled)
      assert Env.get_state(cancelled.env, State.state_key(State)) == nil
    end

    test "cancel without leave_scope (simple suspend, no scoped effects)" do
      comp = Yield.yield(:value) |> Yield.with_handler()
      env = Env.new()
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%ExternalSuspended{}, fiber)

      cancelled = Coroutine.cancel(fiber)

      assert match?(%Cancelled{}, cancelled)
      assert cancelled.env != nil
    end

    test "cancel is no-op on completed fiber" do
      env = Env.new()
      fiber = Coroutine.new(42, env)

      fiber = Coroutine.run(fiber)
      assert match?(%Completed{}, fiber)
      assert fiber.result == 42

      same = Coroutine.cancel(fiber)
      assert match?(%Completed{}, same)
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
      fiber = Coroutine.new(comp, env)

      fiber = Coroutine.run(fiber)
      assert match?(%Errored{}, fiber)
      assert %Error{type: :throw, error: :boom} = fiber.error

      same = Coroutine.cancel(fiber)
      assert match?(%Errored{}, same)
      assert %Error{type: :throw, error: :boom} = same.error
      assert same == fiber
    end

    test "cancel is no-op on already-cancelled fiber" do
      env = Env.new()
      fiber = Coroutine.new(42, env)

      cancelled = Coroutine.cancel(fiber)
      assert match?(%Cancelled{}, cancelled)

      same = Coroutine.cancel(cancelled, :different_reason)
      assert match?(%Cancelled{}, same)
      assert same == cancelled
    end
  end

  describe "Coroutine.terminal?/1" do
    test "pending is not terminal" do
      fiber = Coroutine.new(42, Env.new())
      refute Coroutine.terminal?(fiber)
    end

    test "suspended is not terminal" do
      comp = Yield.yield(:value) |> Yield.with_handler()
      fiber = Coroutine.new(comp, Env.new())

      fiber = Coroutine.run(fiber)
      assert match?(%ExternalSuspended{}, fiber)
      refute Coroutine.terminal?(fiber)
    end

    test "cancelled is terminal" do
      fiber = Coroutine.new(42, Env.new())
      cancelled = Coroutine.cancel(fiber)
      assert Coroutine.terminal?(cancelled)
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
