defmodule Skuld.Effects.NonBlockingAsync.Scheduler.StateTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.NonBlockingAsync.Scheduler.State
  alias Skuld.Effects.NonBlockingAsync.AwaitRequest
  alias AwaitRequest.TaskTarget
  alias AwaitRequest.TimerTarget

  describe "new/1" do
    test "creates empty state" do
      state = State.new()

      assert state.suspended == %{}
      assert state.waiting_for == %{}
      assert :queue.is_empty(state.run_queue)
      assert state.completed == %{}
    end

    test "stores options" do
      state = State.new(on_error: :stop)
      assert state.opts == [on_error: :stop]
    end
  end

  describe "add_suspension/4" do
    test "tracks suspension with request info" do
      state = State.new()
      request = make_request(:all)
      resume = fn _ -> :resumed end

      {:suspended, state} = State.add_suspension(state, request.id, request, resume)

      assert Map.has_key?(state.suspended, request.id)
      info = state.suspended[request.id]
      assert info.request == request
      assert info.resume == resume
      assert info.collected == %{}
      assert is_integer(info.suspended_at)
    end

    test "creates waiting_for reverse index" do
      state = State.new()
      task = make_task()
      timer = TimerTarget.new(1000)
      request = AwaitRequest.new([TaskTarget.new(task), timer], :any)
      resume = fn _ -> :resumed end

      {:suspended, state} = State.add_suspension(state, request.id, request, resume)

      # Both targets should map to this request_id
      assert state.waiting_for[{:task, task.ref}] == request.id
      assert state.waiting_for[{:timer, timer.ref}] == request.id
    end

    test "returns :ready when early completions satisfy wake condition" do
      state = State.new()
      task = make_task()
      request = AwaitRequest.new([TaskTarget.new(task)], :all)
      resume = fn _ -> :resumed end

      # Record completion BEFORE adding suspension
      {:waiting, state} = State.record_completion(state, {:task, task.ref}, {:ok, :early_result})

      # Now add suspension - should immediately be ready
      {:ready, state} = State.add_suspension(state, request.id, request, resume)

      # Should be in run_queue, not suspended
      refute Map.has_key?(state.suspended, request.id)
      assert :queue.len(state.run_queue) == 1
    end

    test "merges early completions into collected when partial" do
      state = State.new()
      task1 = make_task()
      task2 = make_task()
      request = AwaitRequest.new([TaskTarget.new(task1), TaskTarget.new(task2)], :all)
      resume = fn _ -> :resumed end

      # Record completion for first task before suspension
      {:waiting, state} = State.record_completion(state, {:task, task1.ref}, {:ok, :early_result})

      # Add suspension - should be suspended but with collected pre-populated
      {:suspended, state} = State.add_suspension(state, request.id, request, resume)

      info = state.suspended[request.id]
      assert info.collected[{:task, task1.ref}] == {:ok, :early_result}
      # Only waiting for task2 now
      refute Map.has_key?(state.waiting_for, {:task, task1.ref})
      assert state.waiting_for[{:task, task2.ref}] == request.id
    end
  end

  describe "remove_suspension/2" do
    test "removes suspension and waiting_for entries" do
      state = State.new()
      task = make_task()
      request = AwaitRequest.new([TaskTarget.new(task)], :all)
      resume = fn _ -> :resumed end

      {:suspended, state} = State.add_suspension(state, request.id, request, resume)
      assert Map.has_key?(state.suspended, request.id)

      state = State.remove_suspension(state, request.id)

      refute Map.has_key?(state.suspended, request.id)
      refute Map.has_key?(state.waiting_for, {:task, task.ref})
    end

    test "is safe on non-existent request_id" do
      state = State.new()
      state2 = State.remove_suspension(state, make_ref())
      assert state2 == state
    end
  end

  describe "record_completion/3 with :all mode" do
    test "collects result but waits for more" do
      state = State.new()
      task1 = make_task()
      task2 = make_task()
      request = AwaitRequest.new([TaskTarget.new(task1), TaskTarget.new(task2)], :all)
      resume = fn _ -> :resumed end

      {:suspended, state} = State.add_suspension(state, request.id, request, resume)

      # First completion - should wait
      {:waiting, state} = State.record_completion(state, {:task, task1.ref}, {:ok, :result1})

      # Verify collected
      info = state.suspended[request.id]
      assert info.collected[{:task, task1.ref}] == {:ok, :result1}
    end

    test "wakes when all targets complete" do
      state = State.new()
      task1 = make_task()
      task2 = make_task()
      request = AwaitRequest.new([TaskTarget.new(task1), TaskTarget.new(task2)], :all)
      request_id = request.id
      resume = fn results -> {:got, results} end

      {:suspended, state} = State.add_suspension(state, request.id, request, resume)

      # First completion
      {:waiting, state} = State.record_completion(state, {:task, task1.ref}, {:ok, :result1})

      # Second completion - should wake
      {:woke, ^request_id, results, state} =
        State.record_completion(state, {:task, task2.ref}, {:ok, :result2})

      # Results in target order
      assert results == [{:ok, :result1}, {:ok, :result2}]

      # Should be in run queue
      {:ok, {^request_id, ^resume, ^results}, _state} = State.dequeue_one(state)
    end
  end

  describe "record_completion/3 with :any mode" do
    test "wakes immediately on first completion" do
      state = State.new()
      task = make_task()
      timer = TimerTarget.new(1000)
      request = AwaitRequest.new([TaskTarget.new(task), timer], :any)
      request_id = request.id
      resume = fn result -> {:got, result} end

      {:suspended, state} = State.add_suspension(state, request.id, request, resume)

      # First completion - should wake
      {:woke, ^request_id, {target_key, result}, state} =
        State.record_completion(state, {:task, task.ref}, {:ok, :task_result})

      assert target_key == {:task, task.ref}
      assert result == {:ok, :task_result}

      # Should be removed from suspended
      refute Map.has_key?(state.suspended, request_id)
    end
  end

  describe "record_completion/3 edge cases" do
    test "stores completion for unknown target as early completion" do
      state = State.new()
      unknown_ref = make_ref()
      {:waiting, state2} = State.record_completion(state, {:task, unknown_ref}, {:ok, :result})

      # Should be stored as early completion
      assert state2.early_completions[{:task, unknown_ref}] == {:ok, :result}
    end

    test "stores completion after suspension removed as early completion" do
      state = State.new()
      task = make_task()
      request = AwaitRequest.new([TaskTarget.new(task)], :all)

      {:suspended, state} = State.add_suspension(state, request.id, request, fn _ -> :resumed end)
      state = State.remove_suspension(state, request.id)

      # Completion arrives after removal - should be stored as early completion
      {:waiting, state2} = State.record_completion(state, {:task, task.ref}, {:ok, :result})
      assert state2.early_completions[{:task, task.ref}] == {:ok, :result}
    end
  end

  describe "enqueue_ready/4 and dequeue_one/1" do
    test "FIFO ordering" do
      state = State.new()
      id1 = make_ref()
      id2 = make_ref()
      resume1 = fn _ -> :r1 end
      resume2 = fn _ -> :r2 end

      state = State.enqueue_ready(state, id1, resume1, :results1)
      state = State.enqueue_ready(state, id2, resume2, :results2)

      {:ok, {^id1, ^resume1, :results1}, state} = State.dequeue_one(state)
      {:ok, {^id2, ^resume2, :results2}, state} = State.dequeue_one(state)
      {:empty, _state} = State.dequeue_one(state)
    end
  end

  describe "active?/1" do
    test "false when empty" do
      state = State.new()
      refute State.active?(state)
    end

    test "true when suspended" do
      state = State.new()
      request = make_request(:all)
      {:suspended, state} = State.add_suspension(state, request.id, request, fn _ -> :ok end)

      assert State.active?(state)
    end

    test "true when run queue not empty" do
      state = State.new()
      state = State.enqueue_ready(state, make_ref(), fn _ -> :ok end, :results)

      assert State.active?(state)
    end
  end

  describe "counts/1" do
    test "returns correct counts" do
      state = State.new()
      request = make_request(:all)
      {:suspended, state} = State.add_suspension(state, request.id, request, fn _ -> :ok end)
      state = State.enqueue_ready(state, make_ref(), fn _ -> :ok end, :results)
      state = State.record_completed(state, make_ref(), :done)

      counts = State.counts(state)
      assert counts.suspended == 1
      assert counts.ready == 1
      assert counts.completed == 1
    end
  end

  # Helpers

  defp make_task do
    Task.async(fn -> :ok end)
  end

  defp make_request(mode) do
    task = make_task()
    AwaitRequest.new([TaskTarget.new(task)], mode)
  end
end
