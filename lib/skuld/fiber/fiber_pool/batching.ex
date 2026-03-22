# Batch grouping, execution, and fiber resumption for the FiberPool.
#
# This module provides the complete batch lifecycle:
# - Group suspended fibers by their batch_key
# - Execute batch groups using registered executors
# - Match results back to the requesting fibers
# - Pop batch suspensions from state, execute them, and resume fibers with results
defmodule Skuld.Fiber.FiberPool.Batching do
  @moduledoc false

  alias Skuld.Comp
  alias Skuld.Comp.Throw
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Fiber.FiberPool.BatchExecutor
  alias Skuld.Fiber.FiberPool.SchedulerState

  @type fiber_id :: reference()
  @type batch_key :: term()

  @doc """
  Group suspended fibers by batch_key.

  Returns a map of `batch_key => [{fiber_id, InternalSuspend.t()}]`.

  The batch_key is stored directly in the `InternalSuspend.Batch` payload,
  set at suspension time by the caller.

  ## Example

      suspended = [
        {fid1, %InternalSuspend{payload: %InternalSuspend.Batch{batch_key: {:db_fetch, User}, ...}, ...}},
        {fid2, %InternalSuspend{payload: %InternalSuspend.Batch{batch_key: {:db_fetch, User}, ...}, ...}},
        {fid3, %InternalSuspend{payload: %InternalSuspend.Batch{batch_key: {:db_fetch, Post}, ...}, ...}}
      ]

      groups = Batching.group_suspended(suspended)
      # groups = %{
      #   {:db_fetch, User} => [{fid1, suspend1}, {fid2, suspend2}],
      #   {:db_fetch, Post} => [{fid3, suspend3}]
      # }
  """
  @spec group_suspended([{fiber_id, InternalSuspend.t()}]) ::
          %{batch_key => [{fiber_id, InternalSuspend.t()}]}
  def group_suspended(suspended_fibers) do
    Enum.group_by(suspended_fibers, fn {_fid, suspend} ->
      suspend.payload.batch_key
    end)
  end

  @doc """
  Execute a batch group using the registered executor.

  Returns a computation that yields `[{fiber_id, result}]` - a list of
  fiber IDs paired with their individual results.

  Raises if no executor is registered for the batch_key.

  ## Parameters

  - `batch_key` - The batch key for this group
  - `group` - List of `{fiber_id, InternalSuspend.t()}` tuples
  - `env` - The current environment (for executor lookup)
  """
  @spec execute_group(batch_key, [{fiber_id, InternalSuspend.t()}], Comp.Types.env()) ::
          Comp.Types.computation()
  def execute_group(batch_key, group, env) do
    # Build the ops list for the executor: [{request_id, op}]
    ops =
      Enum.map(group, fn {_fid, suspend} -> {suspend.payload.request_id, suspend.payload.op} end)

    case BatchExecutor.get_executor(env, batch_key) do
      nil ->
        # Return a computation that yields a Throw struct directly
        # (not through the Throw effect, which would need a handler)
        fn e, _k -> {%Throw{error: {:no_batch_executor, batch_key}}, e} end

      executor ->
        # Execute the batch and map results back to fiber_ids
        Comp.bind(executor.(ops), fn results ->
          fiber_results =
            Enum.map(group, fn {fiber_id, suspend} ->
              result = Map.fetch!(results, suspend.payload.request_id)
              {fiber_id, result}
            end)

          Comp.pure(fiber_results)
        end)
    end
  end

  @doc """
  Execute all batch groups.

  Returns a computation that yields a flat list of `{fiber_id, result}` tuples
  for all fibers across all batch groups.
  """
  @spec execute_all_groups(%{batch_key => [{fiber_id, InternalSuspend.t()}]}, Comp.Types.env()) ::
          Comp.Types.computation()
  def execute_all_groups(groups, _env) when map_size(groups) == 0 do
    Comp.pure([])
  end

  def execute_all_groups(groups, env) do
    # Execute each group and collect results
    group_list = Map.to_list(groups)

    Enum.reduce(group_list, Comp.pure([]), fn {batch_key, group}, acc_comp ->
      Comp.bind(acc_comp, fn acc_results ->
        Comp.bind(execute_group(batch_key, group, env), fn group_results ->
          Comp.pure(acc_results ++ group_results)
        end)
      end)
    end)
  end

  #############################################################################
  ## Batch Execution and Fiber Resumption
  #############################################################################

  @doc """
  Pop all pending batch suspensions from state, execute them, and resume
  the suspended fibers with their results.

  Groups suspensions by batch_key, executes each group via the registered
  executor, and enqueues the fibers to run with their results.

  Returns `{state, env}` with fibers re-enqueued.
  """
  @spec execute_pending_batches(SchedulerState.t(), Comp.Types.env()) ::
          {SchedulerState.t(), Comp.Types.env()}
  def execute_pending_batches(state, env) do
    {suspensions, state} = SchedulerState.pop_all_batch_suspensions(state)

    if suspensions == [] do
      {state, env}
    else
      groups = group_suspended(suspensions)

      Enum.reduce(groups, {state, env}, fn {batch_key, group}, {acc_state, acc_env} ->
        execute_and_resume(acc_state, acc_env, batch_key, group)
      end)
    end
  end

  # Execute a single batch group and resume its fibers with results
  defp execute_and_resume(state, env, batch_key, group) do
    batch_comp = execute_group(batch_key, group, env)

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

  # Resume a fiber with a batch result by enqueuing it with a wake marker
  defp resume_fiber_with_result(state, fiber_id, result) do
    case SchedulerState.get_fiber(state, fiber_id) do
      nil ->
        state

      _fiber ->
        state = SchedulerState.remove_batch_suspension(state, fiber_id)

        wake_value = unwrap_batch_result(result)

        state =
          put_in(state, [Access.key(:wake_signals), fiber_id], {:batch_wake, wake_value})

        SchedulerState.enqueue(state, fiber_id)
    end
  end

  defp unwrap_batch_result({:ok, value}), do: value

  defp unwrap_batch_result({:error, reason}) do
    %Throw{error: reason}
  end
end
