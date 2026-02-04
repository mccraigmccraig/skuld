defmodule Skuld.Fiber.FiberPool.Scheduler do
  @moduledoc """
  Core scheduling loop for the FiberPool.

  The scheduler runs fibers cooperatively, managing the run queue and handling
  suspensions and completions.

  ## Scheduling Strategy

  - FIFO: Fibers are run in the order they become ready
  - Cooperative: Fibers run until they complete, suspend, or error
  - Fair: Each step runs one fiber, allowing interleaving

  ## Usage

  The scheduler is typically used through the FiberPool effect, not directly.
  For testing or advanced use:

      state = State.new()
      {fiber_id, state} = State.add_fiber(state, fiber)
      {:done, results, state} = Scheduler.run(state, env)
  """

  alias Skuld.Fiber
  alias Skuld.Fiber.FiberPool.State
  alias Skuld.Fiber.FiberPool.EnvState
  alias Skuld.Fiber.FiberPool.PendingWork
  alias Skuld.Comp.Types
  alias Skuld.Comp.Env

  @type step_result ::
          {:continue, State.t()}
          | {:done, State.t()}
          | {:suspended, Fiber.t(), State.t()}
          | {:batch_ready, State.t()}
          | {:error, term(), State.t()}

  @type run_result ::
          {:done, %{reference() => term()}, State.t()}
          | {:suspended, Fiber.t(), State.t()}
          | {:waiting_for_tasks, State.t()}
          | {:batch_ready, State.t()}
          | {:error, term(), State.t()}

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
  @spec run(State.t(), Types.env()) :: run_result()
  def run(state, env) do
    run_loop(state, env)
  end

  @doc """
  Run all ready fibers until the queue is empty.

  Useful for draining the queue after receiving external events.
  Does not block waiting for completions.
  """
  @spec run_ready(State.t(), Types.env()) :: step_result()
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
  @spec step(State.t(), Types.env()) :: step_result()
  def step(state, env) do
    case State.dequeue(state) do
      {:empty, state} ->
        cond do
          State.all_done?(state) ->
            {:done, state}

          State.has_batch_suspensions?(state) ->
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
  Process pending channel wakes from env_state.

  Channel operations (put/take) may wake suspended fibers by adding entries
  to the channel_wakes list in env_state. This function processes those wakes,
  enqueueing the fibers to run with their results.

  Called internally by `run/2`, but also available for use when calling
  `step/2` directly (which does not process wakes automatically).
  """
  @spec process_channel_wakes(State.t()) :: State.t()
  def process_channel_wakes(state) do
    env_state = get_env_state(state)

    if EnvState.has_channel_wakes?(env_state) do
      # Pop wakes and update env_state
      {wakes, env_state} = EnvState.pop_channel_wakes(env_state)
      state = put_env_state(state, env_state)

      Enum.reduce(wakes, state, fn {fiber_id, result}, acc_state ->
        resume_channel_fiber(acc_state, fiber_id, result)
      end)
    else
      state
    end
  end

  #############################################################################
  ## Internal
  #############################################################################

  defp run_loop(state, env) do
    # Process any pending channel wakes before each step
    state = process_channel_wakes(state)

    case step(state, env) do
      {:continue, state} ->
        run_loop(state, env)

      {:done, state} ->
        # Process any final channel wakes
        state = process_channel_wakes(state)

        # Check if we now have work to do
        if State.queue_empty?(state) do
          # Check if there are still running tasks
          if State.has_tasks?(state) do
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
    case State.get_fiber(state, fiber_id) do
      nil ->
        # Fiber was removed (cancelled?) - continue
        {:continue, state}

      fiber ->
        # Check if this is a wake-up (fiber was suspended awaiting or batch)
        {wake_result, state} = State.pop_wake_result(state, fiber_id)

        case wake_result do
          nil ->
            # Normal run - fiber is pending
            run_pending_fiber(state, fiber, env)

          {:batch_wake, result} ->
            # Fiber is being resumed with batch result (unwrap the tuple)
            resume_fiber(state, fiber, result)

          {:channel_wake, result} ->
            # Fiber is being resumed with channel result (unwrap the tuple)
            resume_fiber(state, fiber, result)

          result ->
            # Fiber is being resumed with await result
            # Check for and clean up any consume_ids
            state = pop_and_cleanup_consume_ids(state, fiber_id)
            resume_fiber(state, fiber, result)
        end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp run_pending_fiber(state, fiber, env) do
    # Update fiber's env:
    # - Use fiber's env for per-fiber fields (evidence, leave_scope, transform_suspend)
    # - Inject shared env_state from pool state
    # - Set the current fiber ID for Channel operations
    base_env = fiber.env || env
    fiber_env = %{base_env | state: state.env_state}
    fiber_env = update_env_state_in_env(fiber_env, &EnvState.set_fiber_id(&1, fiber.id))
    fiber = %{fiber | env: fiber_env}

    case Fiber.run_until_suspend(fiber) do
      {:completed, result, final_env} ->
        state = State.put_env_state(state, final_env.state)
        state = collect_pending_fibers(state, final_env)
        handle_completion(state, fiber.id, {:ok, result})

      {:suspended, suspended_fiber} ->
        state = State.put_env_state(state, suspended_fiber.env.state)
        {state, suspended_fiber} = collect_and_clear_pending_fibers(state, suspended_fiber)
        handle_suspension(state, suspended_fiber)

      {:batch_suspended, suspended_fiber, batch_suspend} ->
        state = State.put_env_state(state, suspended_fiber.env.state)
        {state, suspended_fiber} = collect_and_clear_pending_fibers(state, suspended_fiber)
        handle_batch_suspension(state, suspended_fiber, batch_suspend)

      {:channel_suspended, suspended_fiber, channel_suspend} ->
        state = State.put_env_state(state, suspended_fiber.env.state)
        {state, suspended_fiber} = collect_and_clear_pending_fibers(state, suspended_fiber)
        handle_channel_suspension(state, suspended_fiber, channel_suspend)

      {:fp_suspended, suspended_fiber, fp_suspend} ->
        state = State.put_env_state(state, suspended_fiber.env.state)
        {state, suspended_fiber} = collect_and_clear_pending_fibers(state, suspended_fiber)
        handle_fp_suspension(state, suspended_fiber, fp_suspend)

      {:error, reason, error_env} ->
        state = if error_env, do: State.put_env_state(state, error_env.state), else: state
        state = collect_pending_fibers(state, error_env)
        handle_completion(state, fiber.id, {:error, reason})
    end
  end

  defp resume_fiber(state, fiber, result) do
    # Inject shared env_state before resuming
    # Also set the current fiber ID (env_state may have the previous fiber's ID)
    fiber_env = %{fiber.env | state: state.env_state}
    fiber_env = update_env_state_in_env(fiber_env, &EnvState.set_fiber_id(&1, fiber.id))
    fiber = %{fiber | env: fiber_env}

    case Fiber.resume(fiber, result) do
      {:completed, value, final_env} ->
        state = State.put_env_state(state, final_env.state)
        state = collect_pending_fibers(state, final_env)
        handle_completion(state, fiber.id, {:ok, value})

      {:suspended, suspended_fiber} ->
        state = State.put_env_state(state, suspended_fiber.env.state)
        {state, suspended_fiber} = collect_and_clear_pending_fibers(state, suspended_fiber)
        handle_suspension(state, suspended_fiber)

      {:batch_suspended, suspended_fiber, batch_suspend} ->
        state = State.put_env_state(state, suspended_fiber.env.state)
        {state, suspended_fiber} = collect_and_clear_pending_fibers(state, suspended_fiber)
        handle_batch_suspension(state, suspended_fiber, batch_suspend)

      {:channel_suspended, suspended_fiber, channel_suspend} ->
        state = State.put_env_state(state, suspended_fiber.env.state)
        {state, suspended_fiber} = collect_and_clear_pending_fibers(state, suspended_fiber)
        handle_channel_suspension(state, suspended_fiber, channel_suspend)

      {:fp_suspended, suspended_fiber, fp_suspend} ->
        state = State.put_env_state(state, suspended_fiber.env.state)
        {state, suspended_fiber} = collect_and_clear_pending_fibers(state, suspended_fiber)
        handle_fp_suspension(state, suspended_fiber, fp_suspend)

      {:error, reason, error_env} ->
        state = if error_env, do: State.put_env_state(state, error_env.state), else: state
        state = collect_pending_fibers(state, error_env)
        handle_completion(state, fiber.id, {:error, reason})
    end
  end

  # Extract any pending fibers from the env and add them to the scheduler state.
  # Also clears pending work from state.env_state to prevent re-collection
  # when the next fiber runs.
  defp collect_pending_fibers(state, nil), do: state

  defp collect_pending_fibers(state, env) do
    pending_work = get_pending_work(env)

    if PendingWork.has_fibers?(pending_work) do
      {fibers, _pending_work} = PendingWork.take_fibers(pending_work)

      # Add pending fibers to state
      state =
        Enum.reduce(fibers, state, fn {_id, fiber}, acc ->
          {_id, acc} = State.add_fiber(acc, fiber)
          acc
        end)

      # Clear from state.env_state to prevent re-collection when next fiber runs
      clear_pending_work_in_env_state(state)
    else
      state
    end
  end

  # Collect pending fibers and clear them from both the suspended fiber's env
  # AND state.env_state to avoid collecting them again on resume or next fiber run
  defp collect_and_clear_pending_fibers(state, suspended_fiber) do
    env = suspended_fiber.env

    if env == nil do
      {state, suspended_fiber}
    else
      pending_work = get_pending_work(env)

      if PendingWork.has_fibers?(pending_work) do
        {fibers, _pending_work} = PendingWork.take_fibers(pending_work)

        # Add pending fibers to state
        state =
          Enum.reduce(fibers, state, fn {_id, fiber}, acc ->
            {_id, acc} = State.add_fiber(acc, fiber)
            acc
          end)

        # Clear pending work from the suspended fiber's env
        cleared_env = clear_pending_work(env)
        suspended_fiber = %{suspended_fiber | env: cleared_env}

        # Also clear from state.env_state (which was updated before this call)
        # to prevent re-collection when next fiber runs
        state = clear_pending_work_in_env_state(state)

        {state, suspended_fiber}
      else
        {state, suspended_fiber}
      end
    end
  end

  defp handle_completion(state, fiber_id, result) do
    state = State.remove_fiber(state, fiber_id)
    state = State.record_completion(state, fiber_id, result)
    {:continue, state}
  end

  defp handle_suspension(state, fiber) do
    # For now, any suspension is treated as an external yield
    # The FiberPool effect handler will intercept await suspensions
    # and convert them to proper State.suspend_awaiting calls
    state = State.put_fiber(state, fiber)
    {:suspended, fiber, state}
  end

  defp handle_batch_suspension(state, fiber, batch_suspend) do
    # Store the fiber and add to batch-suspended tracking
    state = State.put_fiber(state, fiber)
    state = State.add_batch_suspension(state, fiber.id, batch_suspend)
    {:continue, state}
  end

  defp handle_channel_suspension(state, fiber, _channel_suspend) do
    # Store the fiber and add to channel-suspended tracking
    state = State.put_fiber(state, fiber)
    state = State.add_channel_suspension(state, fiber.id)
    {:continue, state}
  end

  defp handle_fp_suspension(state, fiber, %{
         handles: handles,
         mode: mode,
         consume_ids: consume_ids
       }) do
    # A fiber is awaiting other fibers - use the State's await tracking
    waiting_for = Enum.map(handles, & &1.id)

    case State.suspend_awaiting(state, fiber.id, waiting_for, mode) do
      {:ready, result, state} ->
        # Results already available - resume immediately
        # Clean up consumed fiber IDs if specified
        state = cleanup_consumed_ids(state, consume_ids)
        resume_fiber(state, fiber, result)

      {:suspended, state} ->
        # Need to wait - store the fiber and track consume_ids for later cleanup
        state = State.put_fiber(state, fiber)
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

  # Store consume_ids in suspension for later cleanup
  defp store_consume_ids(state, _fiber_id, []), do: state

  defp store_consume_ids(state, fiber_id, consume_ids) do
    # Store in a special key in the state for retrieval when woken
    key = {:consume_ids, fiber_id}
    put_in(state, [Access.key(:completed), key], consume_ids)
  end

  # Pop and clean up consume_ids when a fiber is woken from await
  defp pop_and_cleanup_consume_ids(state, fiber_id) do
    key = {:consume_ids, fiber_id}

    case Map.pop(state.completed, key) do
      {nil, _} ->
        state

      {consume_ids, completed} ->
        state = %{state | completed: completed}
        cleanup_consumed_ids(state, consume_ids)
    end
  end

  defp collect_results(state) do
    # Return completed results, filtering out wake markers
    state.completed
    |> Enum.reject(fn {key, _} -> match?({:wake, _}, key) end)
    |> Map.new()
  end

  # Resume a fiber that was waiting on a channel operation
  defp resume_channel_fiber(state, fiber_id, result) do
    if State.channel_suspended?(state, fiber_id) do
      # Remove from channel_suspended and enqueue with result
      state = State.remove_channel_suspension(state, fiber_id)

      # Store wake result wrapped in :channel_wake tuple and enqueue
      state =
        put_in(state, [Access.key(:completed), {:wake, fiber_id}], {:channel_wake, result})

      State.enqueue(state, fiber_id)
    else
      # Fiber not found in channel suspensions - might have been cancelled
      state
    end
  end

  #############################################################################
  ## EnvState and PendingWork Helpers
  #############################################################################

  # Get the EnvState from state.env_state, defaulting to a new one
  defp get_env_state(state) do
    Map.get(state.env_state, EnvState.env_key(), EnvState.new())
  end

  # Put the EnvState back into state.env_state
  defp put_env_state(state, env_state) do
    State.put_env_state(state, Map.put(state.env_state, EnvState.env_key(), env_state))
  end

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
    State.put_env_state(state, env_state)
  end

  # Update the EnvState in an env (for setting fiber_id before running)
  defp update_env_state_in_env(env, fun) do
    env_state = Env.get_state(env, EnvState.env_key(), EnvState.new())
    env_state = fun.(env_state)
    Env.put_state(env, EnvState.env_key(), env_state)
  end
end
