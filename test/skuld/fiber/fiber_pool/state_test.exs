defmodule Skuld.Fiber.FiberPool.StateTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Fiber
  alias Skuld.Fiber.FiberPool.State

  describe "new/1" do
    test "creates empty state" do
      state = State.new()

      assert is_reference(state.id)
      assert state.fibers == %{}
      assert :queue.is_empty(state.run_queue)
      assert state.suspended == %{}
      assert state.completed == %{}
      assert state.awaiting == %{}
    end

    test "accepts options" do
      state = State.new(on_error: :stop)

      assert state.opts == [on_error: :stop]
    end
  end

  describe "add_fiber/2" do
    test "adds fiber to state and enqueues it" do
      state = State.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())

      {fiber_id, state} = State.add_fiber(state, fiber)

      assert fiber_id == fiber.id
      assert Map.has_key?(state.fibers, fiber_id)
      refute :queue.is_empty(state.run_queue)
    end
  end

  describe "get_fiber/2" do
    test "returns fiber by id" do
      state = State.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())
      {fiber_id, state} = State.add_fiber(state, fiber)

      result = State.get_fiber(state, fiber_id)

      assert result == fiber
    end

    test "returns nil for unknown id" do
      state = State.new()

      assert State.get_fiber(state, make_ref()) == nil
    end
  end

  describe "dequeue/1" do
    test "dequeues fiber in FIFO order" do
      state = State.new()
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      fiber3 = Fiber.new(Comp.pure(3), Env.new())

      {id1, state} = State.add_fiber(state, fiber1)
      {id2, state} = State.add_fiber(state, fiber2)
      {id3, state} = State.add_fiber(state, fiber3)

      {:ok, dequeued1, state} = State.dequeue(state)
      {:ok, dequeued2, state} = State.dequeue(state)
      {:ok, dequeued3, _state} = State.dequeue(state)

      assert dequeued1 == id1
      assert dequeued2 == id2
      assert dequeued3 == id3
    end

    test "returns empty when queue is empty" do
      state = State.new()

      assert {:empty, _state} = State.dequeue(state)
    end
  end

  describe "record_completion/3" do
    test "records completion result" do
      state = State.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())
      {fiber_id, state} = State.add_fiber(state, fiber)

      state = State.record_completion(state, fiber_id, {:ok, 42})

      assert State.get_result(state, fiber_id) == {:ok, 42}
      assert State.completed?(state, fiber_id)
    end
  end

  describe "suspend_awaiting/4" do
    test "suspends fiber waiting for completed fiber" do
      state = State.new()

      # Add and complete a fiber
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      {fid1, state} = State.add_fiber(state, fiber1)
      state = State.record_completion(state, fid1, {:ok, 1})

      # Add awaiting fiber
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      {fid2, state} = State.add_fiber(state, fiber2)

      # Awaiting already completed fiber should return :ready
      {:ready, result, _state} = State.suspend_awaiting(state, fid2, [fid1], :all)

      assert result == [{:ok, 1}]
    end

    test "suspends fiber waiting for pending fiber" do
      state = State.new()

      # Add a fiber (not completed)
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      {fid1, state} = State.add_fiber(state, fiber1)

      # Add awaiting fiber
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      {fid2, state} = State.add_fiber(state, fiber2)

      # Should suspend
      {:suspended, state} = State.suspend_awaiting(state, fid2, [fid1], :all)

      assert Map.has_key?(state.suspended, fid2)
      assert Map.has_key?(state.awaiting, fid1)
    end

    test "wakes awaiter when target completes" do
      state = State.new()

      # Add a fiber (not completed)
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      {fid1, state} = State.add_fiber(state, fiber1)

      # Dequeue fiber1 to clear the run queue
      {:ok, ^fid1, state} = State.dequeue(state)

      # Add awaiting fiber
      fiber2 = Fiber.new(Comp.pure(2), Env.new())
      {fid2, state} = State.add_fiber(state, fiber2)

      # Dequeue fiber2 to clear the run queue
      {:ok, ^fid2, state} = State.dequeue(state)

      # Suspend fiber2 waiting for fiber1
      {:suspended, state} = State.suspend_awaiting(state, fid2, [fid1], :all)

      # Complete fiber1 - this should wake fiber2
      state = State.record_completion(state, fid1, {:ok, 42})

      # fiber2 should now be in the run queue
      {:ok, queued_fid, _state} = State.dequeue(state)
      assert queued_fid == fid2

      # Wake result should be available
      {wake_result, _state} = State.pop_wake_result(state, fid2)
      assert wake_result == [{:ok, 42}]
    end
  end

  describe "all_done?/1" do
    test "returns true for empty state" do
      state = State.new()

      assert State.all_done?(state)
    end

    test "returns false when fibers exist" do
      state = State.new()
      fiber = Fiber.new(Comp.pure(42), Env.new())
      {_id, state} = State.add_fiber(state, fiber)

      refute State.all_done?(state)
    end
  end

  describe "counts/1" do
    test "returns correct counts" do
      state = State.new()
      fiber1 = Fiber.new(Comp.pure(1), Env.new())
      fiber2 = Fiber.new(Comp.pure(2), Env.new())

      {fid1, state} = State.add_fiber(state, fiber1)
      {_fid2, state} = State.add_fiber(state, fiber2)
      state = State.record_completion(state, fid1, {:ok, 1})

      counts = State.counts(state)

      assert counts.fibers == 2
      assert counts.run_queue == 2
      assert counts.completed == 1
    end
  end
end
