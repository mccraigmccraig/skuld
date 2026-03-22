defmodule Skuld.Fiber.FiberPool.Main do
  @moduledoc """
  Main computation driver for the FiberPool.

  Orchestrates fiber execution on behalf of the main computation — the
  computation passed to `Comp.run/1`. Its responsibilities:

  - **Drain pending work**: `Comp.run/1` calls `drain_pending/2` after
    `Comp.call/3` to schedule any fibers or tasks spawned during execution.
  - **Drive the main computation's await/resume cycle**: when the main
    computation suspends awaiting fiber results, this module steps the
    Scheduler until the await is satisfied, then resumes the main computation.
  - **Run fibers to completion**: when the main computation has already
    finished but background fibers remain, delegates to `Scheduler.run/2`
    to drain them.

  This module does not schedule individual fibers — that's `Scheduler`'s job.
  It sits one level above, calling `Scheduler.step/2` in a loop while checking
  whether the main computation can proceed.

  ## Dependency Layering

  - `Comp` depends on this module (calls `drain_pending/2`)
  - `Skuld.Effects.FiberPool` depends on `Comp` and `Skuld.Fiber.*`
  - This module depends on `Skuld.Fiber.*` (infrastructure only)
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Effects.FiberPool, as: FiberPoolEffect
  alias Skuld.Fiber.FiberPool.SchedulerState, as: State
  alias Skuld.Fiber.FiberPool.Scheduler
  alias Skuld.Fiber.FiberPool.Batching
  alias Skuld.Fiber.FiberPool.PendingWork
  alias Skuld.Fiber.FiberPool.Tasks

  @doc """
  Drain any pending fibers and tasks accumulated during computation execution.

  Called by `Comp.run/1` after `Comp.call/3`. If no fibers or tasks are
  pending (and the result is not an await suspension), this is a fast-path
  no-op.

  Returns `{result, env}` — either the original values unchanged (fast path)
  or the final values after all fibers and tasks have completed.
  """
  @spec drain_pending(term(), Comp.Types.env()) :: {term(), Comp.Types.env()}
  def drain_pending(result, env) do
    pending_work = Env.get_state(env, PendingWork.env_key(), PendingWork.new())
    {pending_fibers, pending_tasks, _} = PendingWork.take_all(pending_work)

    if pending_fibers == [] and pending_tasks == [] and not await_suspend?(result) do
      {result, env}
    else
      task_sup = Env.get_state(env, FiberPoolEffect.task_supervisor_key())
      state = State.new(task_supervisor: task_sup)

      # Seed state.env_state from main computation's env.state,
      # clearing pending work since we've already extracted it
      clean_env_state = Map.put(env.state, PendingWork.env_key(), PendingWork.new())
      state = State.put_env_state(state, clean_env_state)

      run_with_fibers(state, env, result, pending_fibers, pending_tasks)
    end
  end

  #############################################################################
  ## Main Computation Orchestration
  #############################################################################

  defp run_with_fibers(state, env, main_result, pending_fibers, pending_tasks) do
    state =
      Enum.reduce(pending_fibers, state, fn {_id, fiber}, acc ->
        {_id, acc} = State.add_fiber(acc, fiber)
        acc
      end)

    state = Tasks.spawn_pending(state, pending_tasks)

    case main_result do
      %InternalSuspend{payload: %InternalSuspend.Await{}} = suspend ->
        # Main computation is awaiting fiber results — drive the scheduler
        run_scheduler_loop(state, env, suspend)

      result ->
        # Main computation already finished — just drain remaining fibers/tasks
        run_fibers_to_completion(state, env, result)
    end
  end

  # Drain remaining fibers when the main computation has already completed.
  # Delegates to Scheduler.run and handles batch rounds.
  defp run_fibers_to_completion(state, env, result) do
    case Scheduler.run(state, env) do
      {:done, _results, _final_state} ->
        {result, env}

      {:suspended, _fiber, _state} ->
        {result, env}

      {:waiting_for_tasks, state} ->
        _state = Tasks.wait_for_all(state)
        {result, env}

      {:batch_ready, state} ->
        {state, env} = Batching.execute_pending_batches(state, env)
        run_fibers_to_completion(state, env, result)
    end
  end

  #############################################################################
  ## Main Await / Resume Cycle
  #############################################################################

  # The main computation suspended with an await — register the await,
  # then step fibers until it can be satisfied.
  defp run_scheduler_loop(
         state,
         env,
         %InternalSuspend{
           resume: resume,
           payload: %InternalSuspend.Await{handles: handles, mode: mode}
         }
       ) do
    fiber_ids = Enum.map(handles, & &1.id)
    awaiter_id = :main

    await_mode =
      case mode do
        :one -> :all
        :all -> :all
        :any -> :any
      end

    case State.suspend_awaiting(state, awaiter_id, fiber_ids, await_mode) do
      {:ready, result, state} ->
        handle_await_result(state, env, result, resume, mode)

      {:suspended, state} ->
        run_until_await_satisfied(state, env, awaiter_id, resume, mode)
    end
  end

  # Step the scheduler one fiber at a time, checking after each step whether
  # the main computation's await is satisfied.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp run_until_await_satisfied(state, env, awaiter_id, resume, mode) do
    state = Scheduler.process_channel_wakes(state)

    case Scheduler.step(state, env) do
      {:continue, state} ->
        {wake_result, state} = State.pop_wake_result(state, awaiter_id)

        case wake_result do
          nil -> run_until_await_satisfied(state, env, awaiter_id, resume, mode)
          result -> handle_await_result(state, env, result, resume, mode)
        end

      {:done, state} ->
        {wake_result, state} = State.pop_wake_result(state, awaiter_id)

        case wake_result do
          nil ->
            if State.has_tasks?(state) do
              wait_for_task_and_retry(state, env, awaiter_id, resume, mode)
            else
              {{:error, :await_never_satisfied}, env}
            end

          result ->
            handle_await_result(state, env, result, resume, mode)
        end

      {:suspended, _fiber, _state} ->
        {{:error, :external_suspension}, env}

      {:batch_ready, state} ->
        {state, env} = Batching.execute_pending_batches(state, env)
        run_until_await_satisfied(state, env, awaiter_id, resume, mode)

        # Reserved for future error handling
        # {:error, reason, _state} ->
        #   {{:error, reason}, env}
    end
  end

  # Wait for a BEAM task message, then check if the await is now satisfied.
  defp wait_for_task_and_retry(state, env, awaiter_id, resume, mode) do
    {:task_completed, state} = Tasks.receive_message(state)

    {wake_result, state} = State.pop_wake_result(state, awaiter_id)

    case wake_result do
      nil ->
        if State.has_tasks?(state) or not State.queue_empty?(state) do
          run_until_await_satisfied(state, env, awaiter_id, resume, mode)
        else
          {{:error, :await_never_satisfied}, env}
        end

      result ->
        handle_await_result(state, env, result, resume, mode)
    end
  end

  # The main computation's await has been satisfied — resume it and handle
  # whatever comes next (another suspension, completion, or new pending work).
  defp handle_await_result(state, env, result, resume, mode) do
    unwrapped =
      case mode do
        :one ->
          [r] = result
          r

        :all ->
          result

        :any ->
          result
      end

    # Clean pending work from env before resuming to avoid stale entries
    clean_env = %{env | state: Map.put(env.state, PendingWork.env_key(), PendingWork.new())}

    {new_result, new_env} = resume.(unwrapped, clean_env)

    # Collect any new pending work spawned during the continuation
    pending_work = Env.get_state(new_env, PendingWork.env_key(), PendingWork.new())
    {pending_fibers, pending_tasks, _} = PendingWork.take_all(pending_work)

    state =
      Enum.reduce(pending_fibers, state, fn {_id, fiber}, acc ->
        {_id, acc} = State.add_fiber(acc, fiber)
        acc
      end)

    state = Tasks.spawn_pending(state, pending_tasks)

    clean_env_state = Map.put(new_env.state, PendingWork.env_key(), PendingWork.new())
    new_env = %{new_env | state: clean_env_state}

    case new_result do
      %InternalSuspend{payload: %InternalSuspend.Await{}} = suspend ->
        run_scheduler_loop(state, new_env, suspend)

      _ ->
        run_fibers_to_completion(state, new_env, new_result)
    end
  end

  # Check if a result is an await suspension
  defp await_suspend?(%InternalSuspend{payload: %InternalSuspend.Await{}}), do: true
  defp await_suspend?(_), do: false
end
