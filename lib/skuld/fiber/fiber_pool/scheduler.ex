# Core scheduling loop for the FiberPool.
#
# The scheduler runs fibers cooperatively, managing the run queue and handling
# suspensions and completions.
#
# ## Scheduling Strategy
#
# - FIFO: Fibers are run in the order they become ready
# - Cooperative: Fibers run until they complete, suspend, or error
# - Fair: Each step runs one fiber, allowing interleaving
#
# ## Usage
#
# The scheduler is typically used through the FiberPool effect, not directly.
# For testing or advanced use:
#
#     state = FiberPoolState.new()
#     {fiber_id, state} = FiberPoolState.add_fiber(state, fiber)
#     {:done, results, state} = Scheduler.run(state, env)
defmodule Skuld.Fiber.FiberPool.Scheduler do
  @moduledoc false

  alias Skuld.Fiber
  alias Skuld.Fiber.Completed
  alias Skuld.Fiber.Errored
  alias Skuld.Fiber.ExternalSuspended
  alias Skuld.Fiber.InternalSuspended
  alias Skuld.Fiber.FiberPool.FiberPoolState
  alias Skuld.Fiber.FiberPool.PendingWork
  alias Skuld.Comp.Types
  alias Skuld.Comp.Env
  alias Skuld.Comp.InternalSuspend

  @type step_result ::
          {:continue, FiberPoolState.t()}
          | {:done, FiberPoolState.t()}
          | {:suspended, Fiber.t(), FiberPoolState.t()}
          | {:batch_ready, FiberPoolState.t()}
          | {:error, term(), FiberPoolState.t()}

  @type run_result ::
          {:done, %{reference() => term()}, FiberPoolState.t()}
          | {:suspended, Fiber.t(), FiberPoolState.t()}
          | {:waiting_for_tasks, FiberPoolState.t()}
          | {:batch_ready, FiberPoolState.t()}
          | {:error, term(), FiberPoolState.t()}

  #############################################################################
  ## Public API
  #############################################################################

  @doc """
  Run all fibers until completion or external suspension.

  Returns:
  - `{:done, results, state}` - All fibers and tasks completed
  - `{:suspended, fiber, state}` - A fiber yielded externally (not an await)
  - `{:waiting_for_tasks, state}` - Fibers done but tasks still running
  - `{:error, reason, state}` - Fatal error (when on_error: :stop)
  """
  @spec run(FiberPoolState.t(), Types.env()) :: run_result()
  def run(state, env) do
    run_loop(state, env)
  end

  @doc """
  Run all ready fibers until the queue is empty.

  Useful for draining the queue after receiving external events.
  Does not block waiting for completions.
  """
  @spec run_ready(FiberPoolState.t(), Types.env()) :: step_result()
  def run_ready(state, env) do
    case step(state, env) do
      {:continue, state} -> run_ready(state, env)
      other -> other
    end
  end

  @doc """
  Execute one scheduling step.

  Dequeues and runs one fiber. Returns:
  - `{:continue, state}` - Step completed, more work may be available
  - `{:done, state}` - No more work to do
  - `{:suspended, fiber, state}` - Fiber yielded externally
  - `{:batch_ready, state}` - Queue empty but batch suspensions ready for execution
  - `{:error, reason, state}` - Fiber errored (with on_error: :stop)
  """
  @spec step(FiberPoolState.t(), Types.env()) :: step_result()
  def step(state, env) do
    case FiberPoolState.dequeue(state) do
      {:empty, state} ->
        cond do
          FiberPoolState.all_done?(state) ->
            {:done, state}

          FiberPoolState.has_batch_suspensions?(state) ->
            # Batch suspensions are ready for execution
            {:batch_ready, state}

          true ->
            # Fibers are suspended waiting for something else (await, tasks, etc.)
            {:done, state}
        end

      {:ok, fiber_id, state} ->
        run_one_fiber(state, fiber_id, env)
    end
  end

  @doc """
  Process pending external wakes from env_state.

  Channel operations and other external code wake suspended fibers by
  adding {fiber_id, result} entries to `:fiber_pool_wakes` in env_state.
  This function drains that list, removes the suspension, and enqueues
  the fiber with the wake result.

  Called internally by `run/2`; also available for use when calling
  `step/2` directly.
  """
  @spec process_external_wakes(FiberPoolState.t()) :: FiberPoolState.t()
  def process_external_wakes(state) do
    wakes = Map.get(state.env_state, :fiber_pool_wakes, [])

    if wakes == [] do
      state
    else
      state = FiberPoolState.put_env_state(state, Map.delete(state.env_state, :fiber_pool_wakes))

      Enum.reduce(wakes, state, fn {fiber_id, result}, acc_state ->
        if FiberPoolState.suspended?(acc_state, fiber_id) do
          acc_state
          |> FiberPoolState.delete_suspension(fiber_id)
          |> then(fn s ->
            put_in(s, [Access.key(:wake_signals), fiber_id], {:external_wake, result})
          end)
          |> then(&FiberPoolState.enqueue(&1, fiber_id))
        else
          acc_state
        end
      end)
    end
  end

  #############################################################################
  ## Internal
  #############################################################################

  defp run_loop(state, env) do
    # Process any pending channel wakes before each step
    state = process_external_wakes(state)

    case step(state, env) do
      {:continue, state} ->
        run_loop(state, env)

      {:done, state} ->
        # Process any final channel wakes
        state = process_external_wakes(state)

        # Check if we now have work to do
        if FiberPoolState.queue_empty?(state) do
          # Check if there are still running tasks
          if FiberPoolState.has_tasks?(state) do
            {:waiting_for_tasks, state}
          else
            # Collect results for completed fibers/tasks
            results = collect_results(state)
            {:done, results, state}
          end
        else
          run_loop(state, env)
        end

      {:suspended, fiber, state} ->
        {:suspended, fiber, state}

      {:batch_ready, state} ->
        # Batch suspensions are ready - return control for batch execution
        {:batch_ready, state}

        # Reserved for future error handling with on_error: :stop
        # {:error, reason, state} ->
        #   {:error, reason, state}
    end
  end

  defp run_one_fiber(state, fiber_id, env) do
    case FiberPoolState.get_fiber(state, fiber_id) do
      nil ->
        # Fiber was removed (cancelled?) - continue
        {:continue, state}

      fiber ->
        # Check if this is a wake-up (fiber was suspended awaiting or batch)
        {wake_result, state} = FiberPoolState.pop_wake_result(state, fiber_id)

        case wake_result do
          nil ->
            # Normal run - fiber is pending
            run_pending_fiber(state, fiber, env)

          {:batch_wake, result} ->
            # Fiber is being resumed with batch result (unwrap the tuple)
            resume_fiber(state, fiber, result)

          {:external_wake, result} ->
            # Fiber is being resumed with external wake result (unwrap the tuple)
            resume_fiber(state, fiber, result)

          result ->
            # Fiber is being resumed with await result
            # Check for and clean up any consume_ids
            state = pop_and_cleanup_consume_ids(state, fiber_id)
            resume_fiber(state, fiber, result)
        end
    end
  end

  defp run_pending_fiber(state, fiber, _env) do
    fiber_env = %{fiber.env | state: state.env_state}

    fiber_env = Env.put_state(fiber_env, :current_fiber_id, fiber.id)

    fiber = %{fiber | env: fiber_env}

    fiber
    |> Fiber.run()
    |> handle_fiber_result(state)
  end

  defp resume_fiber(state, fiber, result) do
    # Inject shared env_state before resuming
    # Also set the current fiber ID (env_state may have the previous fiber's ID)
    fiber_env = %{fiber.env | state: state.env_state}

    fiber_env = Env.put_state(fiber_env, :current_fiber_id, fiber.id)

    fiber = %{fiber | env: fiber_env}

    fiber
    |> Fiber.run(result)
    |> handle_fiber_result(state)
  end

  # Handle the result of running or resuming a fiber.
  # Switch on the fiber's struct type.
  defp handle_fiber_result(%Completed{result: result, env: env} = fiber, state) do
    state = FiberPoolState.put_env_state(state, env.state)
    state = collect_pending_fibers(state, env)
    handle_completion(state, fiber.id, {:ok, result})
  end

  defp handle_fiber_result(%ExternalSuspended{env: env} = fiber, state) do
    state = FiberPoolState.put_env_state(state, env.state)
    {state, fiber} = collect_and_clear_pending_fibers(state, fiber)
    handle_suspension(state, fiber)
  end

  defp handle_fiber_result(
         %InternalSuspended{
           env: env,
           suspend: %InternalSuspend{payload: payload} = internal_suspend
         } = fiber,
         state
       ) do
    state = FiberPoolState.put_env_state(state, env.state)
    {state, fiber} = collect_and_clear_pending_fibers(state, fiber)
    handle_internal_suspension(state, fiber, internal_suspend, payload)
  end

  defp handle_fiber_result(%Errored{error: error, env: env} = fiber, state) do
    state = FiberPoolState.put_env_state(state, env.state)
    state = collect_pending_fibers(state, env)
    handle_completion(state, fiber.id, {:error, error})
  end

  # Extract any pending fibers from the env and add them to the scheduler state.
  # Also clears pending work from state.env_state to prevent re-collection
  # when the next fiber runs.
  defp collect_pending_fibers(state, env) do
    {state, _env} = drain_pending_fibers(state, env)
    state
  end

  # Collect pending fibers and clear them from both the suspended fiber's env
  # AND state.env_state to avoid collecting them again on resume or next fiber run.
  defp collect_and_clear_pending_fibers(state, suspended_fiber) do
    {state, cleaned_env} = drain_pending_fibers(state, suspended_fiber.env)
    {state, %{suspended_fiber | env: cleaned_env}}
  end

  # Core extraction: take fibers from env, add to state, clear env's pending work.
  # Returns {state, env} with pending work cleared.
  defp drain_pending_fibers(state, env) do
    pending_work = get_pending_work(env)

    if PendingWork.has_fibers?(pending_work) do
      {fibers, _pending_work} = PendingWork.take_fibers(pending_work)

      state =
        Enum.reduce(fibers, state, fn {_id, fiber}, acc ->
          {_id, acc} = FiberPoolState.add_fiber(acc, fiber)
          acc
        end)

      cleared_env = clear_pending_work(env)
      state = clear_pending_work_in_env_state(state)
      {state, cleared_env}
    else
      {state, env}
    end
  end

  defp handle_completion(state, fiber_id, result) do
    state = FiberPoolState.remove_fiber(state, fiber_id)
    state = FiberPoolState.record_completion(state, fiber_id, result)
    {:continue, state}
  end

  defp handle_suspension(state, fiber) do
    # For now, any suspension is treated as an external yield
    # The FiberPool effect handler will intercept await suspensions
    # and convert them to proper FiberPoolState.suspend_awaiting calls
    state = FiberPoolState.put_fiber(state, fiber)
    {:suspended, fiber, state}
  end

  # Dispatch internal suspensions based on payload type
  defp handle_internal_suspension(state, fiber, internal_suspend, %InternalSuspend.Batch{}) do
    # Store the fiber and add to batch-suspended tracking
    state = FiberPoolState.put_fiber(state, fiber)
    state = FiberPoolState.add_batch_suspension(state, fiber.id, internal_suspend)
    {:continue, state}
  end

  defp handle_internal_suspension(state, fiber, _internal_suspend, %InternalSuspend.Channel{}) do
    # Store the fiber and add to channel-suspended tracking
    state = FiberPoolState.put_fiber(state, fiber)
    state = FiberPoolState.put_suspension(state, fiber.id, %FiberPoolState.Suspension.Channel{})
    {:continue, state}
  end

  defp handle_internal_suspension(state, fiber, _internal_suspend, %InternalSuspend.Await{
         handles: handles,
         mode: mode,
         consume_ids: consume_ids
       }) do
    # A fiber is awaiting other fibers - use the State's await tracking
    waiting_for = Enum.map(handles, & &1.id)

    case FiberPoolState.suspend_awaiting(state, fiber.id, waiting_for, mode) do
      {:ready, result, state} ->
        # Results already available - resume immediately
        # Clean up consumed fiber IDs if specified
        state = cleanup_consumed_ids(state, consume_ids)
        resume_fiber(state, fiber, result)

      {:suspended, state} ->
        # Need to wait - store the fiber and track consume_ids for later cleanup
        state = FiberPoolState.put_fiber(state, fiber)
        # Store consume_ids in suspension info for cleanup when woken
        state = store_consume_ids(state, fiber.id, consume_ids)
        {:continue, state}
    end
  end

  # Clean up fiber results that have been consumed (single-consumer optimization)
  defp cleanup_consumed_ids(state, []), do: state

  defp cleanup_consumed_ids(state, consume_ids) do
    Enum.reduce(consume_ids, state, fn fid, acc ->
      %{acc | completed: Map.delete(acc.completed, fid)}
    end)
  end

  # Store consume_ids for later cleanup when the awaiting fiber is woken
  defp store_consume_ids(state, _fiber_id, []), do: state

  defp store_consume_ids(state, fiber_id, consume_ids) do
    put_in(state, [Access.key(:consume_ids), fiber_id], consume_ids)
  end

  # Pop and clean up consume_ids when a fiber is woken from await
  defp pop_and_cleanup_consume_ids(state, fiber_id) do
    case Map.pop(state.consume_ids, fiber_id) do
      {nil, _} ->
        state

      {consume_ids, remaining} ->
        state = %{state | consume_ids: remaining}
        cleanup_consumed_ids(state, consume_ids)
    end
  end

  defp collect_results(state) do
    state.completed
  end

  #############################################################################
  ## PendingWork Helpers
  #############################################################################

  # Get the PendingWork from an env, defaulting to empty
  defp get_pending_work(env) do
    Env.get_state(env, PendingWork.env_key(), PendingWork.new())
  end

  # Clear the PendingWork in an env
  defp clear_pending_work(env) do
    Env.put_state(env, PendingWork.env_key(), PendingWork.new())
  end

  # Clear the PendingWork in state.env_state
  defp clear_pending_work_in_env_state(state) do
    env_state = Map.put(state.env_state, PendingWork.env_key(), PendingWork.new())
    FiberPoolState.put_env_state(state, env_state)
  end

  # Update the ChannelCoordinationState in an env (for setting fiber_id before running)
end
