# BEAM Task integration for FiberPool.
#
# This module handles spawning and receiving results from BEAM Tasks
# that run in parallel processes. Tasks are used when you need true
# parallelism (multiple CPU cores) rather than cooperative concurrency
# (fibers in a single process).
#
# ## Usage
#
# Tasks are spawned via `FiberPool.task/2` and awaited like fibers:
#
#     comp do
#       # Spawn a task (runs in separate process)
#       h <- FiberPool.task(fn -> expensive_cpu_work() end)
#
#       # Await result (suspends until task completes)
#       result <- FiberPool.await!(h)
#     end
#
# ## Integration
#
# The FiberPool scheduler calls these functions to:
# 1. Spawn pending tasks after the main computation runs
# 2. Wait for task completion messages
# 3. Record task results for await satisfaction
defmodule Skuld.Fiber.FiberPool.Tasks do
  @moduledoc false

  alias Skuld.Fiber.FiberPool.State
  alias Skuld.Comp.Throw

  @type task_info :: {reference(), (-> term()), keyword()}

  @doc """
  Spawn pending tasks using the Task.Supervisor.

  Takes a list of `{handle_id, thunk, opts}` tuples and spawns each
  as an async task. The task results are sent back as messages and
  handled by `receive_message/1`.
  """
  @spec spawn_pending(State.t(), [task_info()]) :: State.t()
  def spawn_pending(state, pending_tasks) do
    task_sup = state.task_supervisor

    Enum.reduce(pending_tasks, state, fn {handle_id, thunk, opts}, acc ->
      _timeout = Keyword.get(opts, :timeout, 5000)

      # Spawn the task - it runs the thunk and sends result back
      task =
        Task.Supervisor.async_nolink(task_sup, fn ->
          # Call the thunk directly - no env/effects, just pure computation
          thunk.()
        end)

      # Track the task by its ref
      State.add_task(acc, task.ref, handle_id)
    end)
  end

  @doc """
  Wait for all remaining tasks to complete.

  Blocks until all tracked tasks have sent their completion messages.
  Returns the updated state with all task results recorded.
  """
  @spec wait_for_all(State.t()) :: State.t()
  def wait_for_all(state) do
    if State.has_tasks?(state) do
      {:task_completed, state} = receive_message(state)
      wait_for_all(state)
    else
      state
    end
  end

  @doc """
  Receive and handle a single task message.

  Blocks until a task completion or crash message is received.
  Records the result (success or error) in the state.

  Returns `{:task_completed, state}` with the updated state.
  """
  @spec receive_message(State.t()) :: {:task_completed, State.t()}
  def receive_message(state) do
    receive do
      {ref, result} when is_reference(ref) ->
        # Task completed
        Process.demonitor(ref, [:flush])
        handle_task_result(state, ref, result)

      {:DOWN, ref, :process, _pid, reason} ->
        # Task crashed
        handle_task_crash(state, ref, reason)
    end
  end

  #############################################################################
  ## Internal
  #############################################################################

  defp handle_task_result(state, ref, result) do
    case State.pop_task(state, ref) do
      {nil, state} ->
        # Unknown task ref, ignore
        {:task_completed, state}

      {handle_id, state} ->
        # Check if result is a Throw sentinel (task computation raised/threw)
        completion =
          case result do
            %Throw{error: error} ->
              {:error, {:task_throw, error}}

            _ ->
              {:ok, result}
          end

        state = State.record_completion(state, handle_id, completion)
        {:task_completed, state}
    end
  end

  defp handle_task_crash(state, ref, reason) do
    case State.pop_task(state, ref) do
      {nil, state} ->
        # Unknown task, ignore
        {:task_completed, state}

      {handle_id, state} ->
        # Record error
        state = State.record_completion(state, handle_id, {:error, {:task_crashed, reason}})
        {:task_completed, state}
    end
  end
end
