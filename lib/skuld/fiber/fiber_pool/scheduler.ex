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
  alias Skuld.Comp.Types

  @type step_result ::
          {:continue, State.t()}
          | {:done, State.t()}
          | {:suspended, Fiber.t(), State.t()}
          | {:error, term(), State.t()}

  @type run_result ::
          {:done, %{reference() => term()}, State.t()}
          | {:suspended, Fiber.t(), State.t()}
          | {:error, term(), State.t()}

  #############################################################################
  ## Public API
  #############################################################################

  @doc """
  Run all fibers until completion or external suspension.

  Returns:
  - `{:done, results, state}` - All fibers completed, results map by fiber_id
  - `{:suspended, fiber, state}` - A fiber yielded externally (not an await)
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
  - `{:error, reason, state}` - Fiber errored (with on_error: :stop)
  """
  @spec step(State.t(), Types.env()) :: step_result()
  def step(state, env) do
    case State.dequeue(state) do
      {:empty, state} ->
        if State.all_done?(state) do
          {:done, state}
        else
          # Fibers are suspended, waiting for something
          {:done, state}
        end

      {:ok, fiber_id, state} ->
        run_one_fiber(state, fiber_id, env)
    end
  end

  #############################################################################
  ## Internal
  #############################################################################

  defp run_loop(state, env) do
    case step(state, env) do
      {:continue, state} ->
        run_loop(state, env)

      {:done, state} ->
        # Collect results for completed fibers
        results = collect_results(state)
        {:done, results, state}

      {:suspended, fiber, state} ->
        {:suspended, fiber, state}

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
        # Check if this is a wake-up (fiber was suspended awaiting)
        {wake_result, state} = State.pop_wake_result(state, fiber_id)

        case wake_result do
          nil ->
            # Normal run - fiber is pending
            run_pending_fiber(state, fiber, env)

          result ->
            # Fiber is being resumed with await result
            resume_fiber(state, fiber, result)
        end
    end
  end

  defp run_pending_fiber(state, fiber, env) do
    # Update fiber's env if needed (inherit from pool env)
    fiber =
      if fiber.env == nil do
        %{fiber | env: env}
      else
        fiber
      end

    case Fiber.run_until_suspend(fiber) do
      {:completed, result, _final_env} ->
        handle_completion(state, fiber.id, {:ok, result})

      {:suspended, suspended_fiber} ->
        handle_suspension(state, suspended_fiber)

      {:error, reason, _env} ->
        handle_completion(state, fiber.id, {:error, reason})
    end
  end

  defp resume_fiber(state, fiber, result) do
    case Fiber.resume(fiber, result) do
      {:completed, value, _final_env} ->
        handle_completion(state, fiber.id, {:ok, value})

      {:suspended, suspended_fiber} ->
        handle_suspension(state, suspended_fiber)

      {:error, reason, _env} ->
        handle_completion(state, fiber.id, {:error, reason})
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

  defp collect_results(state) do
    # Return completed results, filtering out wake markers
    state.completed
    |> Enum.reject(fn {key, _} -> match?({:wake, _}, key) end)
    |> Map.new()
  end
end
