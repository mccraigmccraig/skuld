defmodule Skuld.ForeignSuspendTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp.Env
  alias Skuld.Comp.ForeignSuspend
  alias Skuld.Comp.ISentinel
  alias Skuld.Coroutine
  alias Skuld.Coroutine.Completed
  alias Skuld.Coroutine.ForeignSuspended
  alias Skuld.Coroutine.ForeignSuspensions

  describe "Comp.ForeignSuspend" do
    test "creates a foreign suspend with resume and payload" do
      resume = fn val, env -> {val, env} end
      fs = %ForeignSuspend{id: 1, resume: resume, payload: :my_promise}

      assert fs.id == 1
      assert fs.resume == resume
      assert fs.payload == :my_promise
    end

    test "ISentinel.run passes through to caller" do
      fs = %ForeignSuspend{id: 1, resume: fn v, e -> {v, e} end, payload: :p}
      env = Env.new()

      assert {^fs, ^env} = ISentinel.run(fs, env)
    end

    test "ISentinel.run! raises" do
      fs = %ForeignSuspend{id: 1, resume: fn v, e -> {v, e} end, payload: :p}

      assert_raise RuntimeError, ~r/must be handled by a scheduler/, fn ->
        ISentinel.run!(fs)
      end
    end

    test "ISentinel marks as sentinel and suspend, not error" do
      fs = %ForeignSuspend{id: 1, resume: fn v, e -> {v, e} end, payload: :p}

      assert ISentinel.sentinel?(fs)
      assert ISentinel.suspend?(fs)
      refute ISentinel.error?(fs)
    end
  end

  describe "Coroutine.ForeignSuspended" do
    test "creates per-fiber foreign suspended state" do
      suspend = %ForeignSuspend{id: 1, resume: fn v, e -> {v, e} end, payload: :p}
      env = Env.new()

      fiber = %ForeignSuspended{id: :fiber_1, suspend: suspend, env: env}

      assert fiber.id == :fiber_1
      assert fiber.suspend == suspend
      assert fiber.env == env
    end
  end

  describe "Coroutine.ForeignSuspensions" do
    test "creates aggregate with suspensions list and resume closure" do
      suspends = [
        %ForeignSuspend{id: 1, resume: fn v, e -> {v, e} end, payload: :p1},
        %ForeignSuspend{id: 2, resume: fn v, e -> {v, e} end, payload: :p2}
      ]

      resume = fn _resolved ->
        %ForeignSuspensions{id: :agg, suspensions: [], env: Env.new(), resume: fn _ -> :done end}
      end

      env = Env.new()
      agg = %ForeignSuspensions{id: :agg, suspensions: suspends, env: env, resume: resume}

      assert length(agg.suspensions) == 2
      assert agg.resume == resume
    end

    test "ISentinel.run passes through to caller" do
      env = Env.new()
      fs = %ForeignSuspensions{id: :a, suspensions: [], env: env, resume: fn _ -> :done end}

      assert {^fs, ^env} = ISentinel.run(fs, env)
    end

    test "ISentinel.run! raises" do
      fs = %ForeignSuspensions{id: :a, suspensions: [], env: Env.new(), resume: fn _ -> :done end}

      assert_raise RuntimeError, ~r/must be handled by a foreign scheduler/, fn ->
        ISentinel.run!(fs)
      end
    end
  end

  describe "Coroutine.call/2 with ForeignSuspended" do
    test "resumes a foreign-suspended fiber" do
      suspend = %ForeignSuspend{
        id: 1,
        resume: fn val, env -> {val * 2, env} end,
        payload: :p
      }

      env = Env.new()
      fiber = %ForeignSuspended{id: :f1, suspend: suspend, env: env}

      result = Coroutine.call(fiber, 21)

      assert %Completed{id: :f1, result: 42} = result
    end
  end

  describe "Coroutine.call/2 with ForeignSuspensions" do
    test "delegates to resume closure with resolved map" do
      suspends = [
        %ForeignSuspend{id: 1, resume: fn v, e -> {v, e} end, payload: :p1}
      ]

      resume = fn resolved ->
        assert resolved == %{1 => :done}
        {:closure_returned, Env.new()}
      end

      env = Env.new()
      agg = %ForeignSuspensions{id: :a, suspensions: suspends, env: env, resume: resume}

      result = Coroutine.call(agg, %{1 => :done})
      assert %Completed{id: :a, result: :closure_returned} = result
    end
  end

  describe "Coroutine.run/2 with ForeignSuspended and ForeignSuspensions" do
    test "run ForeignSuspended resumes and runs through ISentinel" do
      suspend = %ForeignSuspend{
        id: 1,
        resume: fn val, env -> {val, env} end,
        payload: :p
      }

      env = Env.new()
      fiber = %ForeignSuspended{id: :f1, suspend: suspend, env: env}

      result = Coroutine.run(fiber, 42)

      assert %Completed{id: :f1, result: 42} = result
    end

    test "run ForeignSuspensions delegates to resume closure" do
      resume = fn _resolved -> {:ran, Env.new()} end
      env = Env.new()
      agg = %ForeignSuspensions{id: :a, suspensions: [], env: env, resume: resume}

      result = Coroutine.run(agg, %{1 => :val})
      assert %Completed{id: :a, result: :ran} = result
    end
  end

  describe "Coroutine.cancel/2" do
    test "cancel ForeignSuspended invokes leave_scope" do
      suspend = %ForeignSuspend{id: 1, resume: fn v, e -> {v, e} end, payload: :p}
      env = Env.new()
      fiber = %ForeignSuspended{id: :f1, suspend: suspend, env: env}

      result = Coroutine.cancel(fiber, :timeout)

      assert %Skuld.Coroutine.Cancelled{id: :f1, reason: :timeout} = result
    end

    test "cancel ForeignSuspensions invokes leave_scope" do
      env = Env.new()
      agg = %ForeignSuspensions{id: :a, suspensions: [], env: env, resume: fn _ -> :done end}

      result = Coroutine.cancel(agg, :user_abort)

      assert %Skuld.Coroutine.Cancelled{id: :a, reason: :user_abort} = result
    end

    test "ForeignSuspended is not terminal" do
      suspend = %ForeignSuspend{id: 1, resume: fn v, e -> {v, e} end, payload: :p}
      fiber = %ForeignSuspended{id: :f1, suspend: suspend, env: Env.new()}

      refute Coroutine.terminal?(fiber)
    end

    test "ForeignSuspensions is not terminal" do
      agg = %ForeignSuspensions{
        id: :a,
        suspensions: [],
        env: Env.new(),
        resume: fn _ -> :done end
      }

      refute Coroutine.terminal?(agg)
    end
  end

  describe "Lifecycle" do
    test "full foreign suspend/await/resume cycle" do
      # Create a computation that produces a ForeignSuspend sentinel
      foreign_comp = fn env, k ->
        suspend = %ForeignSuspend{
          id: 42,
          resume: fn val, env2 -> {val, env2} end,
          payload: :test_promise
        }

        k.(suspend, env)
      end

      env = Env.new()
      fiber = Coroutine.new(foreign_comp, env, id: :lifecycle_fiber)

      # Step the fiber — should become ForeignSuspended
      fiber = Coroutine.call(fiber)

      assert %ForeignSuspended{
               id: :lifecycle_fiber,
               suspend: %ForeignSuspend{id: 42, payload: :test_promise}
             } =
               fiber

      # Resume with the resolved value
      fiber = Coroutine.call(fiber, :resolved_value)

      assert %Completed{id: :lifecycle_fiber, result: :resolved_value} = fiber
    end
  end
end
