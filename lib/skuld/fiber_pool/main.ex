defmodule Skuld.FiberPool.Main do
  @moduledoc """
  Main computation driver for the FiberPool.

  Orchestrates fiber execution on behalf of the main computation. Called from
  two sites — each handling a different class of pending work:

  - **`InternalSuspend.ISentinel.run`** — drains `InternalSuspend` sentinels
    (Await, Batch, Channel) at the `Comp.run` boundary. When the main
    computation awaits fiber results and suspends, the scheduler steps fibers
    until the await is satisfied, then resumes the main computation.
  - **`FiberPool.with_handler`** — drains fire-and-forget fibers (spawned but
    not awaited) on normal completion, while scoped effect state is still live.

  This module does not schedule individual fibers — that's `Scheduler`'s job.
  It sits one level above, calling `Scheduler.step/2` in a loop while checking
  whether the main computation can proceed.

  ## Dependency Layering

  - `InternalSuspend` depends on this module (via ISentinel.run → drain_pending)
  - `Skuld.Effects.FiberPool` depends on this module (via with_handler)
  - Both depend on `Comp` and `Skuld.Coroutine.*`
  - `Comp` does **not** depend on any Fiber module

  InternalSuspend sentinels propagate through `Comp.bind` without firing
  continuations, so `drain_comp` inside `FiberPool.with_handler` cannot
  intercept them. `ISentinel` at the `Comp.run` boundary is the natural
  dispatch point.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.ForeignSuspend
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Coroutine
  alias Skuld.Coroutine.ForeignSuspended
  alias Skuld.Coroutine.ForeignSuspensions
  alias Skuld.Coroutine.Pending
  alias Skuld.FiberPool.FiberPoolState
  alias Skuld.FiberPool.Scheduler
  alias Skuld.FiberPool.PendingWork
  alias Skuld.FiberPool.Batching
  alias Skuld.FiberPool.Tasks

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
      task_sup = Env.get_state(env, Skuld.Effects.Task.task_supervisor_key())
      {pool_id, env} = Comp.call(Skuld.Effects.FreshInt.fresh_integer(), env, &Comp.identity_k/2)
      state = FiberPoolState.new(id: pool_id, task_supervisor: task_sup)

      # Seed state.env_state from main computation's env.state,
      # clearing pending work since we've already extracted it
      clean_env_state = Map.put(env.state, PendingWork.env_key(), PendingWork.new())
      state = FiberPoolState.put_env_state(state, clean_env_state)

      run_with_fibers(state, env, result, pending_fibers, pending_tasks)
    end
  end

  #############################################################################
  ## Main Computation Orchestration
  #############################################################################

  defp run_with_fibers(state, env, main_result, pending_fibers, pending_tasks) do
    state =
      Enum.reduce(pending_fibers, state, fn {_id, fiber}, acc ->
        {_id, acc} = FiberPoolState.add_fiber(acc, fiber)
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
    snapshot = FiberPoolState.progress_snapshot(state)

    case Scheduler.run(state, env) do
      {:done, _results, final_state} ->
        {result, %{env | state: FiberPoolState.get_env_state(final_state)}}

      {:suspended, _fiber, final_state} ->
        {result, %{env | state: FiberPoolState.get_env_state(final_state)}}

      {:waiting_for_tasks, state} ->
        final_state = Tasks.wait_for_all(state)
        {result, %{env | state: FiberPoolState.get_env_state(final_state)}}

      {:batch_ready, state} ->
        {state, env} = Batching.execute_pending_batches(state, env)

        if FiberPoolState.progressed?(snapshot, FiberPoolState.progress_snapshot(state)) do
          run_fibers_to_completion(state, env, result)
        else
          {{:error, {:deadlock, deadlock_diagnostic(state)}}, env}
        end

      {:foreign_suspends, state} ->
        bundle_foreign_suspensions(state, env)
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

    case FiberPoolState.suspend_awaiting(state, awaiter_id, fiber_ids, await_mode) do
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
    state = Scheduler.process_external_wakes(state)
    snapshot = FiberPoolState.progress_snapshot(state)

    case Scheduler.step(state, env) do
      {:continue, state} ->
        {wake_result, state} = FiberPoolState.pop_wake_result(state, awaiter_id)

        case wake_result do
          nil ->
            if FiberPoolState.progressed?(snapshot, FiberPoolState.progress_snapshot(state)) do
              run_until_await_satisfied(state, env, awaiter_id, resume, mode)
            else
              {{:error, {:deadlock, deadlock_diagnostic(state)}}, env}
            end

          result ->
            handle_await_result(state, env, result, resume, mode)
        end

      {:done, state} ->
        {wake_result, state} = FiberPoolState.pop_wake_result(state, awaiter_id)

        case wake_result do
          nil ->
            if FiberPoolState.has_tasks?(state) do
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

    {wake_result, state} = FiberPoolState.pop_wake_result(state, awaiter_id)

    case wake_result do
      nil ->
        if FiberPoolState.has_tasks?(state) or not FiberPoolState.queue_empty?(state) do
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
        {_id, acc} = FiberPoolState.add_fiber(acc, fiber)
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

  # Build a diagnostic map for deadlock errors, describing what the scheduler
  # was doing when no progress could be made.
  defp deadlock_diagnostic(state) do
    %{
      counts: FiberPoolState.counts(state),
      suspended_fiber_ids: Map.keys(state.suspensions)
    }
  end

  # Bundle all foreign-suspended fibers into a ForeignSuspensions aggregate
  # with a resume closure that re-enters the scheduler when Promises resolve.
  defp bundle_foreign_suspensions(state, env) do
    suspends =
      for {_fiber_id, %ForeignSuspended{suspend: s}} <- state.foreign_suspends, do: s

    resume = build_foreign_resume(state, env)

    {%ForeignSuspensions{id: state.id, suspensions: suspends, env: env, resume: resume}, env}
  end

  # Build the resume closure that batch-wakes resolved fibers.
  # Takes `%{ForeignSuspend.id => resolved_value}` and re-enters the scheduler.
  defp build_foreign_resume(state, env) do
    fn resolved ->
      resolved_fibers =
        Enum.flat_map(state.foreign_suspends, fn {fiber_id, fiber} ->
          %ForeignSuspended{suspend: %ForeignSuspend{id: s_id} = suspend} = fiber

          case Map.fetch(resolved, s_id) do
            {:ok, value} ->
              {result, new_env} = suspend.resume.(value, fiber.env)
              new_fiber = Coroutine.new(result, new_env, id: s_id)
              [{fiber_id, new_fiber}]

            :error ->
              []
          end
        end)

      # Remove resolved fibers from foreign_suspends and add to run queue
      state =
        Enum.reduce(resolved_fibers, state, fn {fiber_id, _new_fiber}, acc ->
          %{acc | foreign_suspends: Map.delete(acc.foreign_suspends, fiber_id)}
        end)

      state =
        Enum.reduce(resolved_fibers, state, fn {_old_fiber_id, new_fiber}, acc ->
          {_new_id, acc} = FiberPoolState.add_fiber(acc, new_fiber)
          acc
        end)

      # Re-run the scheduler to process any newly ready fibers
      run_fibers_to_completion(state, env, :foreign_resume)
    end
  end

  # Check if a result is an await suspension
  defp await_suspend?(%InternalSuspend{payload: %InternalSuspend.Await{}}), do: true
  defp await_suspend?(_), do: false
end
