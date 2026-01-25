defmodule Skuld.Effects.NonBlockingAsync.AwaitRequestTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.NonBlockingAsync.AwaitRequest
  alias AwaitRequest.Target
  alias AwaitRequest.TaskTarget
  alias AwaitRequest.TimerTarget
  alias AwaitRequest.ComputationTarget
  alias Skuld.AsyncComputation

  describe "AwaitRequest" do
    test "new/2 creates request with :all mode" do
      targets = [TaskTarget.new(make_task())]
      request = AwaitRequest.new(targets, :all)

      assert %AwaitRequest{mode: :all, targets: ^targets} = request
      assert is_reference(request.id)
    end

    test "new/2 creates request with :any mode" do
      targets = [TaskTarget.new(make_task())]
      request = AwaitRequest.new(targets, :any)

      assert %AwaitRequest{mode: :any} = request
    end

    test "target_keys/1 returns keys for all targets" do
      task = make_task()
      timer = TimerTarget.new(1000)

      request = AwaitRequest.new([TaskTarget.new(task), timer], :any)
      keys = AwaitRequest.target_keys(request)

      assert {:task, task.ref} in keys
      assert {:timer, timer.ref} in keys
      assert length(keys) == 2
    end
  end

  describe "TaskTarget" do
    test "new/1 wraps a Task" do
      task = make_task()
      target = TaskTarget.new(task)

      assert %TaskTarget{task: ^task} = target
    end

    test "Target.key/1 returns {:task, ref}" do
      task = make_task()
      target = TaskTarget.new(task)

      assert Target.key(target) == {:task, task.ref}
    end
  end

  describe "TimerTarget" do
    test "new/1 creates timer with deadline in the future" do
      before = System.monotonic_time(:millisecond)
      target = TimerTarget.new(1000)
      after_time = System.monotonic_time(:millisecond)

      assert is_reference(target.ref)
      assert target.deadline >= before + 1000
      assert target.deadline <= after_time + 1000
      assert target.timer_ref == nil
    end

    test "new_absolute/1 creates timer with exact deadline" do
      deadline = System.monotonic_time(:millisecond) + 5000
      target = TimerTarget.new_absolute(deadline)

      assert target.deadline == deadline
    end

    test "Target.key/1 returns {:timer, ref}" do
      target = TimerTarget.new(1000)
      assert Target.key(target) == {:timer, target.ref}
    end

    test "start/1 arms the timer" do
      target = TimerTarget.new(100)
      assert {:ok, started} = TimerTarget.start(target)

      assert is_reference(started.timer_ref)

      # Clean up
      TimerTarget.cancel(started)
    end

    test "start/1 returns :already_expired for past deadline" do
      # Create timer with deadline in the past
      past_deadline = System.monotonic_time(:millisecond) - 1
      target = TimerTarget.new_absolute(past_deadline)

      assert {:already_expired, ^target} = TimerTarget.start(target)
    end

    test "start/1 is idempotent" do
      target = TimerTarget.new(1000)
      {:ok, started1} = TimerTarget.start(target)
      {:ok, started2} = TimerTarget.start(started1)

      assert started1.timer_ref == started2.timer_ref

      TimerTarget.cancel(started2)
    end

    test "cancel/1 cancels running timer" do
      target = TimerTarget.new(1000)
      {:ok, started} = TimerTarget.start(target)

      cancelled = TimerTarget.cancel(started)
      assert cancelled.timer_ref == nil
    end

    test "cancel/1 is safe on unstarted timer" do
      target = TimerTarget.new(1000)
      cancelled = TimerTarget.cancel(target)
      assert cancelled.timer_ref == nil
    end

    test "expired?/1 returns false for future deadline" do
      target = TimerTarget.new(10_000)
      refute TimerTarget.expired?(target)
    end

    test "expired?/1 returns true for past deadline" do
      # Create timer with deadline in the past
      past_deadline = System.monotonic_time(:millisecond) - 1
      target = TimerTarget.new_absolute(past_deadline)

      assert TimerTarget.expired?(target)
    end

    test "timer fires and sends message" do
      target = TimerTarget.new(10)
      {:ok, _started} = TimerTarget.start(target)

      assert_receive {:timeout, ref, :fired}, 100
      assert ref == target.ref
    end
  end

  describe "ComputationTarget" do
    test "new/1 wraps an AsyncComputation runner" do
      runner = make_runner()
      target = ComputationTarget.new(runner)

      assert %ComputationTarget{runner: ^runner} = target
    end

    test "Target.key/1 returns {:computation, tag}" do
      runner = make_runner()
      target = ComputationTarget.new(runner)

      assert Target.key(target) == {:computation, runner.tag}
    end
  end

  # Helpers

  defp make_task do
    Task.async(fn -> :ok end)
  end

  defp make_runner do
    # Create a fake runner struct for testing
    %AsyncComputation{
      tag: :test,
      ref: make_ref(),
      pid: self(),
      monitor_ref: make_ref(),
      caller: self()
    }
  end
end
