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

      assert {:completed, 42, _env} = Fiber.run_until_suspend(fiber)
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

      assert {:completed, {5, 15}, _env} = Fiber.run_until_suspend(fiber)
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

      assert {:suspended, suspended_fiber} = Fiber.run_until_suspend(fiber)
      assert suspended_fiber.status == :suspended
      assert is_function(suspended_fiber.suspended_k, 2)
      assert suspended_fiber.env != nil
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

      assert {:error, {:throw, :my_error}, _env} = Fiber.run_until_suspend(fiber)
    end

    test "elixir raise returns error" do
      comp = fn _env, _k ->
        raise "boom"
      end

      env = Env.new()
      fiber = Fiber.new(comp, env)

      # Comp.call converts exceptions to Throw effects with a map containing
      # :kind, :payload, :stacktrace - which then becomes {:throw, map} error
      assert {:error, {:throw, %{kind: :error, payload: %RuntimeError{message: "boom"}}}, _env} =
               Fiber.run_until_suspend(fiber)
    end

    test "cannot run non-pending fiber" do
      env = Env.new()
      fiber = Fiber.new(Comp.pure(42), env)

      {:completed, _, _} = Fiber.run_until_suspend(fiber)

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

      {:suspended, suspended_fiber} = Fiber.run_until_suspend(fiber)
      assert {:completed, 42, _env} = Fiber.resume(suspended_fiber, 21)
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

      {:suspended, fiber1} = Fiber.run_until_suspend(fiber)
      {:suspended, fiber2} = Fiber.resume(fiber1, 10)
      {:completed, 30, _env} = Fiber.resume(fiber2, 20)
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

      {:suspended, suspended_fiber} = Fiber.run_until_suspend(fiber)
      assert {:error, {:throw, :triggered}, _env} = Fiber.resume(suspended_fiber, :trigger_error)
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
    test "cancels pending fiber" do
      env = Env.new()
      fiber = Fiber.new(Comp.pure(42), env)

      cancelled = Fiber.cancel(fiber)

      assert cancelled.status == :cancelled
      assert cancelled.computation == nil
      assert cancelled.suspended_k == nil
      assert cancelled.env == nil
    end

    test "cancels suspended fiber" do
      comp = Yield.yield(:value) |> Yield.with_handler()
      env = Env.new()
      fiber = Fiber.new(comp, env)

      {:suspended, suspended_fiber} = Fiber.run_until_suspend(fiber)
      cancelled = Fiber.cancel(suspended_fiber)

      assert cancelled.status == :cancelled
      assert cancelled.suspended_k == nil
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

      {:suspended, suspended_fiber} = Fiber.run_until_suspend(fiber)
      refute Fiber.terminal?(suspended_fiber)
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
