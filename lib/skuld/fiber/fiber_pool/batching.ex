defmodule Skuld.Fiber.FiberPool.Batching do
  @moduledoc """
  Batch grouping and execution for the FiberPool scheduler.

  This module provides functions to:
  - Group suspended fibers by their batch_key
  - Execute batch groups using registered executors
  - Match results back to the requesting fibers
  """

  alias Skuld.Comp
  alias Skuld.Comp.Throw
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Fiber.FiberPool.BatchExecutor
  alias Skuld.Fiber.FiberPool.IBatchable

  @type fiber_id :: reference()
  @type batch_key :: term()

  @doc """
  Group suspended fibers by batch_key.

  Returns `{batchable_groups, non_batchable}` where:
  - `batchable_groups` is a map of `batch_key => [{fiber_id, InternalSuspend.t()}]`
  - `non_batchable` is a list of `{fiber_id, InternalSuspend.t()}` with nil batch_key

  ## Example

      suspended = [
        {fid1, %InternalSuspend{payload: %InternalSuspend.Batch{op: %DB.Fetch{...}, ...}, ...}},
        {fid2, %InternalSuspend{payload: %InternalSuspend.Batch{op: %DB.Fetch{...}, ...}, ...}},
        {fid3, %InternalSuspend{payload: %InternalSuspend.Batch{op: %DB.Fetch{...}, ...}, ...}}
      ]

      {groups, non_batchable} = Batching.group_suspended(suspended)
      # groups = %{
      #   {:db_fetch, User} => [{fid1, suspend1}, {fid2, suspend2}],
      #   {:db_fetch, Post} => [{fid3, suspend3}]
      # }
  """
  @spec group_suspended([{fiber_id, InternalSuspend.t()}]) ::
          {%{batch_key => [{fiber_id, InternalSuspend.t()}]}, [{fiber_id, InternalSuspend.t()}]}
  def group_suspended(suspended_fibers) do
    {batchable, non_batchable} =
      Enum.split_with(suspended_fibers, fn {_fid, suspend} ->
        IBatchable.batch_key(suspend.payload.op) != nil
      end)

    groups =
      Enum.group_by(batchable, fn {_fid, suspend} ->
        IBatchable.batch_key(suspend.payload.op)
      end)

    {groups, non_batchable}
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
end
