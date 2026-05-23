defmodule Skuld.FiberPool.FiberPoolStateTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp.Env
  alias Skuld.Coroutine
  alias Skuld.FiberPool.FiberPoolState
  alias Skuld.FiberPool.FiberPoolState.ProgressSnapshot
  alias Skuld.FiberPool.FiberPoolState.Suspension

  describe "new/1" do
    test "creates empty state" do
      state = FiberPoolState.new()

      assert is_reference(state.id)
      assert state.fibers == %{}
      assert :queue.is_empty(state.run_queue)
      assert state.suspensions == %{}
      assert state.completed == %{}
      assert state.awaiting == %{}
    end

    test "accepts options" do
      state = FiberPoolState.new(on_error: :stop)

      assert state.opts == [on_error: :stop]
    end
  end

  describe "add_fiber/2" do
    test "adds fiber to state and enqueues it" do
      state = FiberPoolState.new()
      fiber = Coroutine.new(42, Env.new(), id: 42)

      {fiber_id, state} = FiberPoolState.add_fiber(state, fiber)

      assert fiber_id == fiber.id
      assert Map.has_key?(state.fibers, fiber_id)
      refute :queue.is_empty(state.run_queue)
    end
  end

  describe "get_fiber/2" do
    test "returns fiber by id" do
      state = FiberPoolState.new()
      fiber = Coroutine.new(42, Env.new(), id: 42)
      {fiber_id, state} = FiberPoolState.add_fiber(state, fiber)

      result = FiberPoolState.get_fiber(state, fiber_id)

      assert result == fiber
    end

    test "returns nil for unknown id" do
      state = FiberPoolState.new()

      assert FiberPoolState.get_fiber(state, make_ref()) == nil
    end
  end

  describe "dequeue/1" do
    test "dequeues fiber in FIFO order" do
      state = FiberPoolState.new()
      fiber1 = Coroutine.new(1, Env.new(), id: 1)
      fiber2 = Coroutine.new(2, Env.new(), id: 2)
      fiber3 = Coroutine.new(3, Env.new(), id: 3)

      {id1, state} = FiberPoolState.add_fiber(state, fiber1)
      {id2, state} = FiberPoolState.add_fiber(state, fiber2)
      {id3, state} = FiberPoolState.add_fiber(state, fiber3)

      {:ok, dequeued1, state} = FiberPoolState.dequeue(state)
      {:ok, dequeued2, state} = FiberPoolState.dequeue(state)
      {:ok, dequeued3, _state} = FiberPoolState.dequeue(state)

      assert dequeued1 == id1
      assert dequeued2 == id2
      assert dequeued3 == id3
    end

    test "returns empty when queue is empty" do
      state = FiberPoolState.new()

      assert {:empty, _state} = FiberPoolState.dequeue(state)
    end
  end

  describe "record_completion/3" do
    test "records completion result" do
      state = FiberPoolState.new()
      fiber = Coroutine.new(42, Env.new(), id: 42)
      {fiber_id, state} = FiberPoolState.add_fiber(state, fiber)

      state = FiberPoolState.record_completion(state, fiber_id, {:ok, 42})

      assert FiberPoolState.get_result(state, fiber_id) == {:ok, 42}
      assert FiberPoolState.completed?(state, fiber_id)
    end
  end

  describe "suspend_awaiting/4" do
    test "suspends fiber waiting for completed fiber" do
      state = FiberPoolState.new()

      # Add and complete a fiber
      fiber1 = Coroutine.new(1, Env.new(), id: 1)
      {fid1, state} = FiberPoolState.add_fiber(state, fiber1)
      state = FiberPoolState.record_completion(state, fid1, {:ok, 1})

      # Add awaiting fiber
      fiber2 = Coroutine.new(2, Env.new(), id: 2)
      {fid2, state} = FiberPoolState.add_fiber(state, fiber2)

      # Awaiting already completed fiber should return :ready
      {:ready, result, _state} = FiberPoolState.suspend_awaiting(state, fid2, [fid1], :all)

      assert result == [{:ok, 1}]
    end

    test "suspends fiber waiting for pending fiber" do
      state = FiberPoolState.new()

      # Add a fiber (not completed)
      fiber1 = Coroutine.new(1, Env.new(), id: 1)
      {fid1, state} = FiberPoolState.add_fiber(state, fiber1)

      # Add awaiting fiber
      fiber2 = Coroutine.new(2, Env.new(), id: 2)
      {fid2, state} = FiberPoolState.add_fiber(state, fiber2)

      # Should suspend
      {:suspended, state} = FiberPoolState.suspend_awaiting(state, fid2, [fid1], :all)

      assert Map.has_key?(state.suspensions, fid2)
      assert Map.has_key?(state.awaiting, fid1)
    end

    test "wakes awaiter when target completes" do
      state = FiberPoolState.new()

      # Add a fiber (not completed)
      fiber1 = Coroutine.new(1, Env.new(), id: 1)
      {fid1, state} = FiberPoolState.add_fiber(state, fiber1)

      # Dequeue fiber1 to clear the run queue
      {:ok, ^fid1, state} = FiberPoolState.dequeue(state)

      # Add awaiting fiber
      fiber2 = Coroutine.new(2, Env.new(), id: 2)
      {fid2, state} = FiberPoolState.add_fiber(state, fiber2)

      # Dequeue fiber2 to clear the run queue
      {:ok, ^fid2, state} = FiberPoolState.dequeue(state)

      # Suspend fiber2 waiting for fiber1
      {:suspended, state} = FiberPoolState.suspend_awaiting(state, fid2, [fid1], :all)

      # Complete fiber1 - this should wake fiber2
      state = FiberPoolState.record_completion(state, fid1, {:ok, 42})

      # fiber2 should now be in the run queue
      {:ok, queued_fid, _state} = FiberPoolState.dequeue(state)
      assert queued_fid == fid2

      # Wake result should be available
      {wake_result, _state} = FiberPoolState.pop_wake_result(state, fid2)
      assert wake_result == [{:ok, 42}]
    end
  end

  describe "all_done?/1" do
    test "returns true for empty state" do
      state = FiberPoolState.new()

      assert FiberPoolState.all_done?(state)
    end

    test "returns false when fibers exist" do
      state = FiberPoolState.new()
      fiber = Coroutine.new(42, Env.new(), id: 42)
      {_id, state} = FiberPoolState.add_fiber(state, fiber)

      refute FiberPoolState.all_done?(state)
    end
  end

  describe "counts/1" do
    test "returns correct counts" do
      state = FiberPoolState.new()
      fiber1 = Coroutine.new(1, Env.new(), id: 1)
      fiber2 = Coroutine.new(2, Env.new(), id: 2)

      {fid1, state} = FiberPoolState.add_fiber(state, fiber1)
      {_fid2, state} = FiberPoolState.add_fiber(state, fiber2)
      state = FiberPoolState.record_completion(state, fid1, {:ok, 1})

      counts = FiberPoolState.counts(state)

      assert counts.fibers == 2
      assert counts.run_queue == 2
      assert counts.completed == 1
    end
  end

  describe "progress_snapshot/1" do
    test "captures sizes of all mutable collections" do
      state = FiberPoolState.new()
      snapshot = FiberPoolState.progress_snapshot(state)

      assert snapshot == %ProgressSnapshot{
               fibers: 0,
               run_queue: 0,
               suspensions: 0,
               completed: 0,
               wake_signals: 0,
               tasks: 0
             }
    end

    test "reflects added fibers and completions" do
      state = FiberPoolState.new()
      fiber = Coroutine.new(42, Env.new(), id: 42)
      {fid, state} = FiberPoolState.add_fiber(state, fiber)
      state = FiberPoolState.record_completion(state, fid, {:ok, 42})

      snapshot = FiberPoolState.progress_snapshot(state)

      assert snapshot.fibers == 1
      assert snapshot.run_queue == 1
      assert snapshot.completed == 1
    end
  end

  describe "progressed?/2" do
    test "returns false for identical snapshots" do
      state = FiberPoolState.new()
      snapshot = FiberPoolState.progress_snapshot(state)

      refute FiberPoolState.progressed?(snapshot, snapshot)
    end

    test "returns true when a fiber completes" do
      state = FiberPoolState.new()
      fiber = Coroutine.new(42, Env.new(), id: 42)
      {fid, state} = FiberPoolState.add_fiber(state, fiber)

      before = FiberPoolState.progress_snapshot(state)
      state = FiberPoolState.record_completion(state, fid, {:ok, 42})
      after_ = FiberPoolState.progress_snapshot(state)

      assert FiberPoolState.progressed?(before, after_)
    end

    test "returns true when run queue changes" do
      state = FiberPoolState.new()

      before = FiberPoolState.progress_snapshot(state)

      fiber = Coroutine.new(1, Env.new(), id: 1)
      {_fid, state} = FiberPoolState.add_fiber(state, fiber)
      after_ = FiberPoolState.progress_snapshot(state)

      assert FiberPoolState.progressed?(before, after_)
    end

    test "returns true when a suspension is added" do
      state = FiberPoolState.new()
      fiber1 = Coroutine.new(1, Env.new(), id: 1)
      fiber2 = Coroutine.new(2, Env.new(), id: 2)
      {fid1, state} = FiberPoolState.add_fiber(state, fiber1)
      {fid2, state} = FiberPoolState.add_fiber(state, fiber2)

      before = FiberPoolState.progress_snapshot(state)
      {:suspended, state} = FiberPoolState.suspend_awaiting(state, fid2, [fid1], :all)
      after_ = FiberPoolState.progress_snapshot(state)

      assert FiberPoolState.progressed?(before, after_)
    end

    test "returns true when a task is added" do
      state = FiberPoolState.new()

      before = FiberPoolState.progress_snapshot(state)
      task_ref = make_ref()
      fiber_id = make_ref()
      state = FiberPoolState.add_task(state, task_ref, fiber_id)
      after_ = FiberPoolState.progress_snapshot(state)

      assert FiberPoolState.progressed?(before, after_)
    end

    test "returns true when a batch suspension is added" do
      state = FiberPoolState.new()

      before = FiberPoolState.progress_snapshot(state)
      fiber_id = make_ref()

      state =
        FiberPoolState.add_batch_suspension(state, fiber_id, %Skuld.Comp.InternalSuspend{
          resume: fn _, _ -> nil end,
          payload: %Skuld.Comp.InternalSuspend.Batch{
            batch_key: :test,
            op: :req,
            request_id: make_ref()
          }
        })

      after_ = FiberPoolState.progress_snapshot(state)

      assert FiberPoolState.progressed?(before, after_)
    end

    test "returns true when a channel suspension is added" do
      state = FiberPoolState.new()

      before = FiberPoolState.progress_snapshot(state)
      fiber_id = make_ref()
      state = FiberPoolState.put_suspension(state, fiber_id, %Suspension.Channel{})
      after_ = FiberPoolState.progress_snapshot(state)

      assert FiberPoolState.progressed?(before, after_)
    end

    test "returns true when wake signals change" do
      state = FiberPoolState.new()
      fiber1 = Coroutine.new(1, Env.new(), id: 1)
      fiber2 = Coroutine.new(2, Env.new(), id: 2)
      {fid1, state} = FiberPoolState.add_fiber(state, fiber1)
      {fid2, state} = FiberPoolState.add_fiber(state, fiber2)

      # Dequeue both to clear run queue
      {:ok, ^fid1, state} = FiberPoolState.dequeue(state)
      {:ok, ^fid2, state} = FiberPoolState.dequeue(state)

      # Suspend fid2 awaiting fid1
      {:suspended, state} = FiberPoolState.suspend_awaiting(state, fid2, [fid1], :all)

      before = FiberPoolState.progress_snapshot(state)

      # Complete fid1 — this wakes fid2, adding a wake signal and enqueueing it
      state = FiberPoolState.record_completion(state, fid1, {:ok, 42})
      after_ = FiberPoolState.progress_snapshot(state)

      assert FiberPoolState.progressed?(before, after_)
    end
  end
end
