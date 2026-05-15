defmodule Skuld.FiberPool.SchedulerTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp.Env
  alias Skuld.Coroutine
  alias Skuld.FiberPool.FiberPoolState
  alias Skuld.FiberPool.Scheduler

  describe "step/2" do
    test "runs one fiber and returns :continue" do
      state = FiberPoolState.new()
      env = Env.new()
      fiber = Coroutine.new(42, env)
      {_fid, state} = FiberPoolState.add_fiber(state, fiber)

      {:continue, state} = Scheduler.step(state, env)

      # Fiber completed, removed from fibers
      assert map_size(state.fibers) == 0
    end

    test "returns :done when no work" do
      state = FiberPoolState.new()
      env = Env.new()

      {:done, _state} = Scheduler.step(state, env)
    end
  end

  describe "run/2" do
    test "runs all fibers to completion" do
      state = FiberPoolState.new()
      env = Env.new()

      fiber1 = Coroutine.new(1, env)
      fiber2 = Coroutine.new(2, env)
      fiber3 = Coroutine.new(3, env)

      {fid1, state} = FiberPoolState.add_fiber(state, fiber1)
      {fid2, state} = FiberPoolState.add_fiber(state, fiber2)
      {fid3, state} = FiberPoolState.add_fiber(state, fiber3)

      {:done, results, _state} = Scheduler.run(state, env)

      assert results[fid1] == {:ok, 1}
      assert results[fid2] == {:ok, 2}
      assert results[fid3] == {:ok, 3}
    end

    test "handles empty state" do
      state = FiberPoolState.new()
      env = Env.new()

      {:done, results, _state} = Scheduler.run(state, env)

      assert results == %{}
    end

    test "collects errors from failed fibers" do
      state = FiberPoolState.new()
      env = Env.new()

      # Create a fiber that will error
      error_comp = fn _env, _k ->
        raise "boom"
      end

      fiber = Coroutine.new(error_comp, env)
      {fid, state} = FiberPoolState.add_fiber(state, fiber)

      {:done, results, _state} = Scheduler.run(state, env)

      assert {:error, %Coroutine.Error{type: :exception, error: %RuntimeError{message: "boom"}}} =
               results[fid]
    end
  end

  describe "run_ready/2" do
    test "runs all ready fibers" do
      state = FiberPoolState.new()
      env = Env.new()

      fiber1 = Coroutine.new(1, env)
      fiber2 = Coroutine.new(2, env)

      {_fid1, state} = FiberPoolState.add_fiber(state, fiber1)
      {_fid2, state} = FiberPoolState.add_fiber(state, fiber2)

      {:done, state} = Scheduler.run_ready(state, env)

      assert :queue.is_empty(state.run_queue)
      assert map_size(state.completed) == 2
    end
  end
end
