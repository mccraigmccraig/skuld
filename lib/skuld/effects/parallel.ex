defmodule Skuld.Effects.Parallel do
  @moduledoc """
  Parallel effect - simple fork-join concurrency with built-in boundaries.

  Provides high-level parallel operations where each call is self-contained
  with automatic task management. Unlike `Async`, there are no handles to
  track or boundaries to manage - each operation spawns tasks, awaits results,
  and cleans up automatically.

  ## Basic Usage

      use Skuld.Syntax
      alias Skuld.Comp
      alias Skuld.Effects.{Parallel, Throw}

      # Run multiple computations in parallel, get all results
      comp do
        Parallel.all([
          comp do expensive_work_1() end,
          comp do expensive_work_2() end,
          comp do expensive_work_3() end
        ])
      end
      |> Parallel.with_handler()
      |> Throw.with_handler()
      |> Comp.run!()
      #=> [:result1, :result2, :result3]

  ## Operations

  - `all/1` - Run all computations, return all results (fails if any fail)
  - `race/1` - Run all computations, return first to complete (cancels others)
  - `map/2` - Map a function over items in parallel

  ## Error Handling

  Task failures are caught and returned. For `all/1` and `map/2`, the first
  failure stops waiting and returns the error. For `race/1`, task failures
  are ignored unless all tasks fail.

  ## Handlers

  - `with_handler/1` - Production handler using Task.Supervisor
  - `with_sequential_handler/1` - Testing handler that runs synchronously

  ## BEAM Process Constraints

  Same as `Async` - child tasks get a snapshot of `env` at fork time.
  Changes don't propagate back. Use `AtomicState` for shared mutable state.
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Internal State Keys
  #############################################################################

  @supervisor_key {@sig, :supervisor}

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(AllOp, [:comps])
  def_op(RaceOp, [:comps])
  def_op(MapOp, [:items, :fun])

  #############################################################################
  ## Public Operations
  #############################################################################

  @doc """
  Run multiple computations in parallel, returning all results.

  Returns a list of results in the same order as the input computations.
  If any computation fails, returns `{:error, {:task_failed, reason}}`.

  ## Example

      Parallel.all([
        comp do fetch_user(1) end,
        comp do fetch_user(2) end,
        comp do fetch_user(3) end
      ])
      #=> [%User{id: 1}, %User{id: 2}, %User{id: 3}]
  """
  @spec all(list(Types.computation())) :: Types.computation()
  def all(comps) when is_list(comps) do
    Comp.effect(@sig, %AllOp{comps: comps})
  end

  @doc """
  Run multiple computations in parallel, returning the first to complete.

  The winning result is returned directly. All other tasks are cancelled.
  If all tasks fail, returns `{:error, :all_tasks_failed}`.

  ## Example

      Parallel.race([
        comp do slow_approach() end,
        comp do fast_approach() end,
        comp do medium_approach() end
      ])
      #=> :fast_result  # others cancelled
  """
  @spec race(list(Types.computation())) :: Types.computation()
  def race(comps) when is_list(comps) do
    Comp.effect(@sig, %RaceOp{comps: comps})
  end

  @doc """
  Map a function over items in parallel.

  The function receives each item and should return a computation.
  Results are returned in the same order as the input items.
  If any computation fails, returns `{:error, {:task_failed, reason}}`.

  ## Example

      Parallel.map([1, 2, 3], fn id ->
        comp do
          fetch_user(id)
        end
      end)
      #=> [%User{id: 1}, %User{id: 2}, %User{id: 3}]
  """
  @spec map(list(term()), (term() -> Types.computation())) :: Types.computation()
  def map(items, fun) when is_list(items) and is_function(fun, 1) do
    Comp.effect(@sig, %MapOp{items: items, fun: fun})
  end

  #############################################################################
  ## Production Handler (Task.Supervisor)
  #############################################################################

  @doc """
  Install a production Parallel handler using Task.Supervisor.

  Creates a Task.Supervisor that manages all parallel tasks. The supervisor
  is stopped when the handler scope exits.

  ## Example

      comp do
        Parallel.all([
          comp do :a end,
          comp do :b end
        ])
      end
      |> Parallel.with_handler()
      |> Throw.with_handler()
      |> Comp.run!()
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(comp) do
    comp
    |> Comp.scoped(fn env ->
      {:ok, sup} = Task.Supervisor.start_link()

      modified = Env.put_state(env, @supervisor_key, sup)

      finally_k = fn value, e ->
        sup = Env.get_state(e, @supervisor_key)

        if sup && Process.alive?(sup) do
          try do
            Supervisor.stop(sup, :normal)
          catch
            :exit, _ -> :ok
          end
        end

        cleaned = %{e | state: Map.delete(e.state, @supervisor_key)}

        {value, cleaned}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &handle_parallel/3)
  end

  defp handle_parallel(%AllOp{comps: comps}, env, k) do
    sup = Env.get_state(env, @supervisor_key)

    # Isolate task env from parent's leave_scope to prevent scope cleanup cross-talk
    task_env = Env.with_leave_scope(env, fn result, e -> {result, e} end)

    # Start all tasks
    tasks =
      Enum.map(comps, fn comp ->
        Task.Supervisor.async_nolink(sup, fn ->
          {result, _final_env} = Comp.call(comp, task_env, fn v, e -> {v, e} end)
          result
        end)
      end)

    # Await all tasks, collecting results
    results = await_all_tasks(tasks, sup)

    k.(results, env)
  end

  defp handle_parallel(%RaceOp{comps: comps}, env, k) do
    sup = Env.get_state(env, @supervisor_key)

    # Isolate task env from parent's leave_scope to prevent scope cleanup cross-talk
    task_env = Env.with_leave_scope(env, fn result, e -> {result, e} end)

    # Start all tasks
    tasks =
      Enum.map(comps, fn comp ->
        Task.Supervisor.async_nolink(sup, fn ->
          {result, _final_env} = Comp.call(comp, task_env, fn v, e -> {v, e} end)
          result
        end)
      end)

    # Race: wait for first success, cancel others
    result = race_tasks(tasks, sup)

    k.(result, env)
  end

  defp handle_parallel(%MapOp{items: items, fun: fun}, env, k) do
    sup = Env.get_state(env, @supervisor_key)

    # Isolate task env from parent's leave_scope to prevent scope cleanup cross-talk
    task_env = Env.with_leave_scope(env, fn result, e -> {result, e} end)

    # Start all tasks
    tasks =
      Enum.map(items, fn item ->
        comp = fun.(item)

        Task.Supervisor.async_nolink(sup, fn ->
          {result, _final_env} = Comp.call(comp, task_env, fn v, e -> {v, e} end)
          result
        end)
      end)

    # Await all tasks, collecting results
    results = await_all_tasks(tasks, sup)

    k.(results, env)
  end

  # Await all tasks, return list of results or first error
  defp await_all_tasks(tasks, sup) do
    task_set = MapSet.new(tasks, & &1.ref)

    result = do_await_all(tasks, task_set, [], sup)

    case result do
      {:ok, results} -> Enum.reverse(results)
      {:error, _} = err -> err
    end
  end

  defp do_await_all([], _task_set, acc, _sup), do: {:ok, acc}

  defp do_await_all([task | rest], task_set, acc, sup) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])

        case result do
          %Comp.Throw{error: error} ->
            # Task threw - treat as failure
            cancel_remaining_tasks(rest, sup)
            flush_remaining(MapSet.delete(task_set, ref))
            {:error, {:task_failed, error}}

          _ ->
            do_await_all(rest, MapSet.delete(task_set, ref), [result | acc], sup)
        end

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        # Task crashed - cancel remaining tasks and return error
        cancel_remaining_tasks(rest, sup)
        flush_remaining(MapSet.delete(task_set, ref))
        {:error, {:task_failed, reason}}
    end
  end

  # Race tasks - return first success or error if all fail
  defp race_tasks([], _sup), do: {:error, :all_tasks_failed}

  defp race_tasks(tasks, sup) do
    task_set = MapSet.new(tasks, & &1.ref)
    do_race(tasks, task_set, sup)
  end

  defp do_race([], _task_set, _sup), do: {:error, :all_tasks_failed}

  defp do_race(tasks, task_set, sup) do
    receive do
      {ref, result} ->
        if MapSet.member?(task_set, ref) do
          Process.demonitor(ref, [:flush])

          case result do
            %Comp.Throw{} ->
              # Task threw - treat as failure, keep waiting for others
              remaining = Enum.reject(tasks, &(&1.ref == ref))
              do_race(remaining, MapSet.delete(task_set, ref), sup)

            _ ->
              # Got a success result - cancel all other tasks
              remaining = Enum.reject(tasks, &(&1.ref == ref))
              cancel_remaining_tasks(remaining, sup)
              flush_remaining(MapSet.delete(task_set, ref))
              result
          end
        else
          # Not our task, keep waiting
          do_race(tasks, task_set, sup)
        end

      {:DOWN, ref, :process, _pid, _reason} ->
        if MapSet.member?(task_set, ref) do
          # A task crashed - remove it and keep waiting for others
          remaining = Enum.reject(tasks, &(&1.ref == ref))
          do_race(remaining, MapSet.delete(task_set, ref), sup)
        else
          # Not our task, keep waiting
          do_race(tasks, task_set, sup)
        end
    end
  end

  defp cancel_remaining_tasks(tasks, sup) do
    Enum.each(tasks, fn task ->
      if Process.alive?(sup) && Process.alive?(task.pid) do
        Task.Supervisor.terminate_child(sup, task.pid)
      end

      Process.demonitor(task.ref, [:flush])
    end)
  end

  defp flush_remaining(task_set) do
    Enum.each(task_set, fn ref ->
      receive do
        {^ref, _} -> :ok
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        0 -> :ok
      end
    end)
  end

  #############################################################################
  ## Sequential Handler (Testing)
  #############################################################################

  @doc """
  Install a sequential handler for testing.

  Runs parallel computations sequentially for deterministic behavior.
  Useful for testing logic without concurrency complexity.

  ## Example

      comp do
        Parallel.all([
          comp do :a end,
          comp do :b end
        ])
      end
      |> Parallel.with_sequential_handler()
      |> Throw.with_handler()
      |> Comp.run!()
      #=> [:a, :b]
  """
  @spec with_sequential_handler(Types.computation()) :: Types.computation()
  def with_sequential_handler(comp) do
    Comp.with_handler(comp, @sig, &handle_sequential/3)
  end

  defp handle_sequential(%AllOp{comps: comps}, env, k) do
    result = run_all_sequential(comps, env, [])

    case result do
      {:ok, results, final_env} -> k.(results, final_env)
      {:error, reason} -> k.({:error, reason}, env)
    end
  end

  defp handle_sequential(%RaceOp{comps: comps}, env, k) do
    # In sequential mode, "race" just returns the first one
    case comps do
      [] ->
        k.({:error, :all_tasks_failed}, env)

      [first | _rest] ->
        {result, final_env} = Comp.call(first, env, fn v, e -> {v, e} end)

        case result do
          %Comp.Throw{error: error} ->
            k.({:error, {:task_failed, error}}, env)

          _ ->
            k.(result, final_env)
        end
    end
  end

  defp handle_sequential(%MapOp{items: items, fun: fun}, env, k) do
    comps = Enum.map(items, fun)
    result = run_all_sequential(comps, env, [])

    case result do
      {:ok, results, final_env} -> k.(results, final_env)
      {:error, reason} -> k.({:error, reason}, env)
    end
  end

  defp run_all_sequential([], env, acc), do: {:ok, Enum.reverse(acc), env}

  defp run_all_sequential([comp | rest], env, acc) do
    {result, new_env} = Comp.call(comp, env, fn v, e -> {v, e} end)

    case result do
      %Comp.Throw{error: error} ->
        {:error, {:task_failed, error}}

      _ ->
        run_all_sequential(rest, new_env, [result | acc])
    end
  end

  #############################################################################
  ## IHandler Implementation (not used directly)
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(_op, _env, _k) do
    raise "Parallel.handle/3 should not be called directly - use with_handler/1 or with_sequential_handler/1"
  end
end
