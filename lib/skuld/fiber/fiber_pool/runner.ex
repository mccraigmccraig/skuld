defmodule Skuld.Fiber.FiberPool.Runner do
  @moduledoc """
  Fiber execution engine for the FiberPool.

  This module contains the scheduling and execution logic that `Comp.run/1`
  uses to drain pending fibers and tasks accumulated during computation
  execution. It was extracted from `Skuld.Effects.FiberPool` to keep the
  dependency layering clean:

  - `Comp` depends on `Skuld.Fiber.*` (including this module)
  - `Skuld.Effects.FiberPool` depends on `Comp` and `Skuld.Fiber.*` (effect uses core)
  - This module depends on `Skuld.Fiber.*` (infrastructure only)
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Throw
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Effects.FiberPool, as: FiberPoolEffect
  alias Skuld.Fiber.FiberPool.State
  alias Skuld.Fiber.FiberPool.Scheduler
  alias Skuld.Fiber.FiberPool.Batching
  alias Skuld.Fiber.FiberPool.PendingWork
  alias Skuld.Fiber.FiberPool.Tasks

  @doc """
  Drain any pending fibers and tasks accumulated during computation execution.

  This is called by `Comp.run/1` after `Comp.call/3` to schedule and execute
  any fibers or tasks that were spawned during the computation. If no fibers
  or tasks are pending (and the result is not an await suspension), this is
  a fast-path no-op.

  Returns `{result, env}` — either the original values unchanged (fast path)
  or the final values after all fibers and tasks have completed.
  """
  @spec drain_pending(term(), Comp.Types.env()) :: {term(), Comp.Types.env()}
  def drain_pending(result, env) do
    # Extract pending work from env
    pending_work = Env.get_state(env, PendingWork.env_key(), PendingWork.new())
    {pending_fibers, pending_tasks, _} = PendingWork.take_all(pending_work)

    if pending_fibers == [] and pending_tasks == [] and not await_suspend?(result) do
      # No fibers or tasks spawned, simple completion
      {result, env}
    else
      # Read task supervisor from env (installed by with_task_supervisor, or nil)
      task_sup = Env.get_state(env, FiberPoolEffect.task_supervisor_key())

      state = State.new(task_supervisor: task_sup)

      # Seed state.env_state from main computation's env.state
      # But clear pending work since we've already extracted it
      clean_env_state = Map.put(env.state, PendingWork.env_key(), PendingWork.new())

      state = State.put_env_state(state, clean_env_state)
      # Run fibers and tasks
      run_with_fibers(state, env, result, pending_fibers, pending_tasks)
    end
  end

  #############################################################################
  ## Fiber Execution
  #############################################################################

  defp run_with_fibers(state, env, main_result, pending_fibers, pending_tasks) do
    # Add pending fibers to state
    state =
      Enum.reduce(pending_fibers, state, fn {_id, fiber}, acc ->
        {_id, acc} = State.add_fiber(acc, fiber)
        acc
      end)

    # Spawn pending tasks
    state = Tasks.spawn_pending(state, pending_tasks)

    # If main result is a suspension, we need to handle it specially
    case main_result do
      %InternalSuspend{payload: %InternalSuspend.Await{}} = suspend ->
        # Main computation is awaiting - need to run fibers/tasks and handle await
        run_scheduler_loop(state, env, suspend)

      result ->
        # Main computation completed - just run remaining fibers/tasks
        run_fibers_to_completion(state, env, result)
    end
  end

  # Run all fibers to completion, handling batch and channel suspensions
  defp run_fibers_to_completion(state, env, result) do
    # Note: Scheduler.run processes channel wakes internally via run_loop
    case Scheduler.run(state, env) do
      {:done, _results, _final_state} ->
        {result, env}

      {:suspended, _fiber, _state} ->
        # External suspension - shouldn't happen in normal operation
        {result, env}

      {:waiting_for_tasks, state} ->
        # Fibers done but tasks still running - wait for them
        _state = Tasks.wait_for_all(state)
        {result, env}

      {:batch_ready, state} ->
        # Execute batches and continue
        {state, env} = execute_batches(state, env)
        run_fibers_to_completion(state, env, result)
    end
  end

  # Execute all pending batch suspensions
  defp execute_batches(state, env) do
    {suspensions, state} = State.pop_all_batch_suspensions(state)

    if suspensions == [] do
      {state, env}
    else
      # Group suspensions by batch_key
      groups = Batching.group_suspended(suspensions)

      # Execute each batch group
      Enum.reduce(groups, {state, env}, fn {batch_key, group}, {acc_state, acc_env} ->
        execute_batch_group(acc_state, acc_env, batch_key, group)
      end)
    end
  end

  # Execute a single batch group
  defp execute_batch_group(state, env, batch_key, group) do
    batch_comp = Batching.execute_group(batch_key, group, env)

    # Run the batch computation
    case Comp.call(batch_comp, env, &Comp.identity_k/2) do
      {%Throw{error: error}, new_env} ->
        # Batch execution failed - resume all fibers with error
        state =
          Enum.reduce(group, state, fn {fiber_id, _suspend}, acc ->
            resume_fiber_with_result(acc, fiber_id, {:error, error})
          end)

        {state, new_env}

      {fiber_results, new_env} when is_list(fiber_results) ->
        # Resume each fiber with its result
        state =
          Enum.reduce(fiber_results, state, fn {fiber_id, result}, acc ->
            resume_fiber_with_result(acc, fiber_id, {:ok, result})
          end)

        {state, new_env}
    end
  end

  # Resume a fiber with a batch result
  defp resume_fiber_with_result(state, fiber_id, result) do
    # Remove from fibers map and re-add to run queue
    case State.get_fiber(state, fiber_id) do
      nil ->
        state

      _fiber ->
        # The fiber is already in the fibers map with suspended_k set
        # Just enqueue it to run
        state = State.remove_batch_suspension(state, fiber_id)

        # Store wake result wrapped in :batch_wake tuple (to distinguish from nil)
        # and enqueue
        wake_value = unwrap_batch_result(result)

        state =
          put_in(state, [Access.key(:completed), {:wake, fiber_id}], {:batch_wake, wake_value})

        State.enqueue(state, fiber_id)
    end
  end

  # Unwrap batch result for resuming fiber
  defp unwrap_batch_result({:ok, value}), do: value

  defp unwrap_batch_result({:error, reason}) do
    # Return the error as a Throw so the fiber sees an error
    %Throw{error: reason}
  end

  # Run scheduler loop, handling FiberPool suspensions (main computation awaiting fibers)
  defp run_scheduler_loop(
         state,
         env,
         %InternalSuspend{
           resume: resume,
           payload: %InternalSuspend.Await{handles: handles, mode: mode}
         }
       ) do
    # Convert handles to fiber_ids
    fiber_ids = Enum.map(handles, & &1.id)

    # For the main computation, we use a special marker
    awaiter_id = :main

    await_mode =
      case mode do
        :one -> :all
        :all -> :all
        :any -> :any
      end

    case State.suspend_awaiting(state, awaiter_id, fiber_ids, await_mode) do
      {:ready, result, state} ->
        # Results already available
        handle_await_result(state, env, result, resume, mode)

      {:suspended, state} ->
        # Need to run fibers until we can satisfy the await
        run_until_await_satisfied(state, env, awaiter_id, resume, mode)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp run_until_await_satisfied(state, env, awaiter_id, resume, mode) do
    # Process any pending channel wakes first (Scheduler.step doesn't do this automatically)
    state = Scheduler.process_channel_wakes(state)

    case Scheduler.step(state, env) do
      {:continue, state} ->
        # Check if our await is now satisfied
        {wake_result, state} = State.pop_wake_result(state, awaiter_id)

        case wake_result do
          nil ->
            # Not yet satisfied, continue running
            run_until_await_satisfied(state, env, awaiter_id, resume, mode)

          result ->
            handle_await_result(state, env, result, resume, mode)
        end

      {:done, state} ->
        # All fibers done - check if our await was satisfied or tasks pending
        {wake_result, state} = State.pop_wake_result(state, awaiter_id)

        case wake_result do
          nil ->
            # Check if we're waiting for tasks
            if State.has_tasks?(state) do
              # Wait for task messages
              wait_for_task_and_retry(state, env, awaiter_id, resume, mode)
            else
              # Await was never satisfied - this is an error
              {{:error, :await_never_satisfied}, env}
            end

          result ->
            handle_await_result(state, env, result, resume, mode)
        end

      {:suspended, _fiber, _state} ->
        # A fiber yielded externally - for now, treat as error
        {{:error, :external_suspension}, env}

      {:batch_ready, state} ->
        # Execute batches and continue running fibers
        {state, env} = execute_batches(state, env)
        run_until_await_satisfied(state, env, awaiter_id, resume, mode)

        # Reserved for future error handling
        # {:error, reason, _state} ->
        #   {{:error, reason}, env}
    end
  end

  # Wait for a task message, record its result, and retry the await
  defp wait_for_task_and_retry(state, env, awaiter_id, resume, mode) do
    {:task_completed, state} = Tasks.receive_message(state)

    # Check if this satisfied our await
    {wake_result, state} = State.pop_wake_result(state, awaiter_id)

    case wake_result do
      nil ->
        # Still not satisfied, keep waiting or continue
        if State.has_tasks?(state) or not State.queue_empty?(state) do
          run_until_await_satisfied(state, env, awaiter_id, resume, mode)
        else
          {{:error, :await_never_satisfied}, env}
        end

      result ->
        handle_await_result(state, env, result, resume, mode)
    end
  end

  defp handle_await_result(state, env, result, resume, mode) do
    # Unwrap result based on mode
    # State returns:
    # - :all mode -> [{:ok, v1}, {:ok, v2}, ...] (results in order)
    # - :any mode -> {fid, {:ok, value}} (first completed)
    unwrapped =
      case mode do
        :one ->
          # Result is [{:ok, value}] - extract the single result tuple
          [r] = result
          r

        :all ->
          # Result is list of {:ok, v} | {:error, e} in order
          result

        :any ->
          # Result is {fid, {:ok, value}} or {fid, {:error, reason}}
          result
      end

    # Clean pending work from env before resuming to avoid stale entries
    # (the env flowing through run_scheduler_loop may still have PendingWork
    # from before the fibers were added to state in run_with_fibers)
    clean_env = %{env | state: Map.put(env.state, PendingWork.env_key(), PendingWork.new())}

    # Resume the main computation with clean env
    {new_result, new_env} = resume.(unwrapped, clean_env)

    # Extract any new pending work spawned during the continuation
    # (same pattern as run/2 lines 347-361)
    pending_work = Env.get_state(new_env, PendingWork.env_key(), PendingWork.new())
    {pending_fibers, pending_tasks, _} = PendingWork.take_all(pending_work)

    # Add new fibers to state
    state =
      Enum.reduce(pending_fibers, state, fn {_id, fiber}, acc ->
        {_id, acc} = State.add_fiber(acc, fiber)
        acc
      end)

    # Spawn new tasks
    state = Tasks.spawn_pending(state, pending_tasks)

    # Clear pending work from env
    clean_env_state = Map.put(new_env.state, PendingWork.env_key(), PendingWork.new())
    new_env = %{new_env | state: clean_env_state}

    # Check if we got another suspension
    case new_result do
      %InternalSuspend{payload: %InternalSuspend.Await{}} = suspend ->
        run_scheduler_loop(state, new_env, suspend)

      _ ->
        # Main computation completed - run any remaining fibers/tasks
        run_fibers_to_completion(state, new_env, new_result)
    end
  end

  # Check if a result is an await suspension
  defp await_suspend?(%InternalSuspend{payload: %InternalSuspend.Await{}}), do: true
  defp await_suspend?(_), do: false
end
