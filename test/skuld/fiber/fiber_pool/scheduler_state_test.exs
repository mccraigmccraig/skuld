defmodule Skuld.Fiber.FiberPool.SchedulerStateTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Fiber
  alias Skuld.Fiber.FiberPool.SchedulerState

  describe "new/1" do
    test "creates empty state" do
      state = SchedulerState.new()

      assert is_reference(state.id)
      assert state.fibers == %{}
      assert :queue.is_empty(state.run_queue)
      assert state.suspended == %{}
      assert state.completed == %{}
      assert state.awaiting == %{}
    end

    test "accepts options" do
      state = SchedulerState.new(on_error: :stop)

      assert state.opts == [on_error: :stop]
    end
  end

  describe "add_fiber/2" do
    test "adds fiber to state and enqueues it" do
      state = SchedulerState.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())

      {fiber_id, state} = SchedulerState.add_fiber(state, fiber)

      assert fiber_id == fiber.id
      assert Map.has_key?(state.fibers, fiber_id)
      refute :queue.is_empty(state.run_queue)
    end
  end

  describe "get_fiber/2" do
    test "returns fiber by id" do
      state = SchedulerState.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())
      {fiber_id, state} = SchedulerState.add_fiber(state, fiber)

      result = SchedulerState.get_fiber(state, fiber_id)

      assert result == fiber
    end

    test "returns nil for unknown id" do
      state = SchedulerState.new()

      assert SchedulerState.get_fiber(state, make_ref()) == nil
    end
  end

  describe "dequeue/1" do
    test "dequeues fiber in FIFO order" do
      state = SchedulerState.new()
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      fiber3 = Fiber.new(Comp.pure(3), Env.new())

      {id1, state} = SchedulerState.add_fiber(state, fiber1)
      {id2, state} = SchedulerState.add_fiber(state, fiber2)
      {id3, state} = SchedulerState.add_fiber(state, fiber3)

      {:ok, dequeued1, state} = SchedulerState.dequeue(state)
      {:ok, dequeued2, state} = SchedulerState.dequeue(state)
      {:ok, dequeued3, _state} = SchedulerState.dequeue(state)

      assert dequeued1 == id1
      assert dequeued2 == id2
      assert dequeued3 == id3
    end

    test "returns empty when queue is empty" do
      state = SchedulerState.new()

      assert {:empty, _state} = SchedulerState.dequeue(state)
    end
  end

  describe "record_completion/3" do
    test "records completion result" do
      state = SchedulerState.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())
      {fiber_id, state} = SchedulerState.add_fiber(state, fiber)

      state = SchedulerState.record_completion(state, fiber_id, {:ok, 42})

      assert SchedulerState.get_result(state, fiber_id) == {:ok, 42}
      assert SchedulerState.completed?(state, fiber_id)
    end
  end

  describe "suspend_awaiting/4" do
    test "suspends fiber waiting for completed fiber" do
      state = SchedulerState.new()

      # Add and complete a fiber
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      {fid1, state} = SchedulerState.add_fiber(state, fiber1)
      state = SchedulerState.record_completion(state, fid1, {:ok, 1})

      # Add awaiting fiber
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      {fid2, state} = SchedulerState.add_fiber(state, fiber2)

      # Awaiting already completed fiber should return :ready
      {:ready, result, _state} = SchedulerState.suspend_awaiting(state, fid2, [fid1], :all)

      assert result == [{:ok, 1}]
    end

    test "suspends fiber waiting for pending fiber" do
      state = SchedulerState.new()

      # Add a fiber (not completed)
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      {fid1, state} = SchedulerState.add_fiber(state, fiber1)

      # Add awaiting fiber
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      {fid2, state} = SchedulerState.add_fiber(state, fiber2)

      # Should suspend
      {:suspended, state} = SchedulerState.suspend_awaiting(state, fid2, [fid1], :all)

      assert Map.has_key?(state.suspended, fid2)
      assert Map.has_key?(state.awaiting, fid1)
    end

    test "wakes awaiter when target completes" do
      state = SchedulerState.new()

      # Add a fiber (not completed)
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      {fid1, state} = SchedulerState.add_fiber(state, fiber1)

      # Dequeue fiber1 to clear the run queue
      {:ok, ^fid1, state} = SchedulerState.dequeue(state)

      # Add awaiting fiber
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      {fid2, state} = SchedulerState.add_fiber(state, fiber2)

      # Dequeue fiber2 to clear the run queue
      {:ok, ^fid2, state} = SchedulerState.dequeue(state)

      # Suspend fiber2 waiting for fiber1
      {:suspended, state} = SchedulerState.suspend_awaiting(state, fid2, [fid1], :all)

      # Complete fiber1 - this should wake fiber2
      state = SchedulerState.record_completion(state, fid1, {:ok, 42})

      # fiber2 should now be in the run queue
      {:ok, queued_fid, _state} = SchedulerState.dequeue(state)
      assert queued_fid == fid2

      # Wake result should be available
      {wake_result, _state} = SchedulerState.pop_wake_result(state, fid2)
      assert wake_result == [{:ok, 42}]
    end
  end

  describe "all_done?/1" do
    test "returns true for empty state" do
      state = SchedulerState.new()

      assert SchedulerState.all_done?(state)
    end

    test "returns false when fibers exist" do
      state = SchedulerState.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())
      {_id, state} = SchedulerState.add_fiber(state, fiber)

      refute SchedulerState.all_done?(state)
    end
  end

  describe "counts/1" do
    test "returns correct counts" do
      state = SchedulerState.new()
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      fiber2 = Fiber.new(Comp.pure(2), Env.new())

      {fid1, state} = SchedulerState.add_fiber(state, fiber1)
      {_fid2, state} = SchedulerState.add_fiber(state, fiber2)
      state = SchedulerState.record_completion(state, fid1, {:ok, 1})

      counts = SchedulerState.counts(state)

      assert counts.fibers == 2
      assert counts.run_queue == 2
      assert counts.completed == 1
    end
  end

  describe "progress_snapshot/1" do
    test "captures sizes of all mutable collections" do
      state = SchedulerState.new()
      snapshot = SchedulerState.progress_snapshot(state)

      assert snapshot == %{
               fibers: 0,
               run_queue: 0,
               suspended: 0,
               completed: 0,
               wake_signals: 0,
               tasks: 0,
               batch_suspended: 0,
               channel_suspended: 0
             }
    end

    test "reflects added fibers and completions" do
      state = SchedulerState.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())
      {fid, state} = SchedulerState.add_fiber(state, fiber)
      state = SchedulerState.record_completion(state, fid, {:ok, 42})

      snapshot = SchedulerState.progress_snapshot(state)

      assert snapshot.fibers == 1
      assert snapshot.run_queue == 1
      assert snapshot.completed == 1
    end
  end

  describe "progressed?/2" do
    test "returns false for identical snapshots" do
      state = SchedulerState.new()
      snapshot = SchedulerState.progress_snapshot(state)

      refute SchedulerState.progressed?(snapshot, snapshot)
    end

    test "returns true when a fiber completes" do
      state = SchedulerState.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())
      {fid, state} = SchedulerState.add_fiber(state, fiber)

      before = SchedulerState.progress_snapshot(state)
      state = SchedulerState.record_completion(state, fid, {:ok, 42})
      after_ = SchedulerState.progress_snapshot(state)

      assert SchedulerState.progressed?(before, after_)
    end

    test "returns true when run queue changes" do
      state = SchedulerState.new()

      before = SchedulerState.progress_snapshot(state)

      fiber = Fiber.new(Comp.pure(1), Env.new())
      {_fid, state} = SchedulerState.add_fiber(state, fiber)
      after_ = SchedulerState.progress_snapshot(state)

      assert SchedulerState.progressed?(before, after_)
    end

    test "returns true when a suspension is added" do
      state = SchedulerState.new()
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      {fid1, state} = SchedulerState.add_fiber(state, fiber1)
      {fid2, state} = SchedulerState.add_fiber(state, fiber2)

      before = SchedulerState.progress_snapshot(state)
      {:suspended, state} = SchedulerState.suspend_awaiting(state, fid2, [fid1], :all)
      after_ = SchedulerState.progress_snapshot(state)

      assert SchedulerState.progressed?(before, after_)
    end

    test "returns true when a task is added" do
      state = SchedulerState.new()

      before = SchedulerState.progress_snapshot(state)
      task_ref = make_ref()
      fiber_id = make_ref()
      state = SchedulerState.add_task(state, task_ref, fiber_id)
      after_ = SchedulerState.progress_snapshot(state)

      assert SchedulerState.progressed?(before, after_)
    end

    test "returns true when a batch suspension is added" do
      state = SchedulerState.new()

      before = SchedulerState.progress_snapshot(state)
      fiber_id = make_ref()

      state =
        SchedulerState.add_batch_suspension(state, fiber_id, %Skuld.Comp.InternalSuspend{
          resume: fn _, _ -> nil end,
          payload: %Skuld.Comp.InternalSuspend.Batch{
            batch_key: :test,
            op: :req,
            request_id: make_ref()
          }
        })

      after_ = SchedulerState.progress_snapshot(state)

      assert SchedulerState.progressed?(before, after_)
    end

    test "returns true when a channel suspension is added" do
      state = SchedulerState.new()

      before = SchedulerState.progress_snapshot(state)
      fiber_id = make_ref()
      state = SchedulerState.add_channel_suspension(state, fiber_id)
      after_ = SchedulerState.progress_snapshot(state)

      assert SchedulerState.progressed?(before, after_)
    end

    test "returns true when wake signals change" do
      state = SchedulerState.new()
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      {fid1, state} = SchedulerState.add_fiber(state, fiber1)
      {fid2, state} = SchedulerState.add_fiber(state, fiber2)

      # Dequeue both to clear run queue
      {:ok, ^fid1, state} = SchedulerState.dequeue(state)
      {:ok, ^fid2, state} = SchedulerState.dequeue(state)

      # Suspend fid2 awaiting fid1
      {:suspended, state} = SchedulerState.suspend_awaiting(state, fid2, [fid1], :all)

      before = SchedulerState.progress_snapshot(state)

      # Complete fid1 — this wakes fid2, adding a wake signal and enqueueing it
      state = SchedulerState.record_completion(state, fid1, {:ok, 42})
      after_ = SchedulerState.progress_snapshot(state)

      assert SchedulerState.progressed?(before, after_)
    end
  end
end
