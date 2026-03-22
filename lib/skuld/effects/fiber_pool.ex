defmodule Skuld.Effects.FiberPool do
  @moduledoc """
  Effect for cooperative fiber-based concurrency.

  FiberPool provides lightweight cooperative concurrency within a single process.
  Fibers are scheduled cooperatively - they run until they await, complete, or error.

  ## Basic Usage

      comp do
        # Run work as a fiber (cooperative, same process)
        h1 <- FiberPool.fiber(expensive_computation())
        h2 <- FiberPool.fiber(another_computation())

        # Do other work while fibers run...

        # Await results (raises on error)
        r1 <- FiberPool.await!(h1)
        r2 <- FiberPool.await!(h2)

        {r1, r2}
      end
      |> FiberPool.with_handler()
      |> Comp.run()

  ## Structured Concurrency

  Use `scope/1` to ensure all spawned fibers complete before exiting:

      comp do
        FiberPool.scope(comp do
          h1 <- FiberPool.fiber(work1())
          h2 <- FiberPool.fiber(work2())
          # Both h1 and h2 will complete (or be cancelled) before scope exits
          FiberPool.await_all!([h1, h2])
        end)
      end

  ## Comparison with Async

  FiberPool replaces the Async effect with a simpler, more focused design:
  - Fibers only (no Tasks in this module - see Task integration milestone)
  - Simpler state management
  - Designed for I/O batching integration
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Throw
  alias Skuld.Fiber
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Fiber.Handle
  alias Skuld.Fiber.FiberPool.State
  alias Skuld.Fiber.FiberPool.Scheduler
  alias Skuld.Fiber.FiberPool.Batching
  alias Skuld.Fiber.FiberPool.PendingWork
  alias Skuld.Fiber.FiberPool.Tasks

  @sig __MODULE__

  #############################################################################
  ## Operations
  #############################################################################

  defmodule FiberOp do
    @moduledoc false
    defstruct [:comp, :opts]
  end

  defmodule Await do
    @moduledoc false
    # raising: true for await!, false for await
    # consume: true to remove result from completed after retrieval (single-consumer optimization)
    defstruct [:handle, raising: true, consume: false]
  end

  defmodule AwaitAll do
    @moduledoc false
    defstruct [:handles, raising: true]
  end

  defmodule AwaitAny do
    @moduledoc false
    defstruct [:handles, raising: true]
  end

  defmodule Cancel do
    @moduledoc false
    defstruct [:handle]
  end

  defmodule TaskOp do
    @moduledoc false
    defstruct [:thunk, :opts]
  end

  defmodule Scope do
    @moduledoc false
    defstruct [:comp, :on_exit]
  end

  #############################################################################
  ## Public API
  #############################################################################

  @doc """
  Run a computation as a fiber (cooperative, same process).

  Returns a handle that can be used to await the result.

  ## Options

  - `:priority` - Fiber priority (future use)
  """
  @spec fiber(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def fiber(computation, opts \\ []) do
    Comp.effect(@sig, %FiberOp{comp: computation, opts: opts})
  end

  @doc """
  Run a thunk as a BEAM Task (parallel, separate process).

  The thunk runs in a separate BEAM process, allowing true parallelism
  for CPU-bound work. Returns a handle that can be awaited just like
  fiber handles.

  **Important:** The thunk is a zero-arity function, not a computation.
  Effects do not work inside tasks because they run in a different process.
  Extract any values you need from Reader/State before constructing the thunk.

  ## Why thunks, not computations?

  Tasks run in a separate BEAM process. While an effectful computation *could*
  be shipped to the other process and executed there, the modified environment
  it returns would then need to be integrated back into the calling process's
  environment. There is no general way to do this — environment changes from
  effects (State mutations, Writer accumulations, handler installations, etc.)
  have no guarantee of commutativity, so a task's environment modifications
  cannot be safely merged with whatever the calling process has done in the
  meantime.

  Restricting tasks to plain thunks forces the caller to explicitly extract
  any needed values from the environment *before* spawning the task, and to
  explicitly handle the task's return value *after* awaiting it. This makes
  the cross-process boundary visible and avoids the need for an unsound
  automatic environment merge.

  ## Options

  - `:timeout` - Task timeout in milliseconds (default: 5000)

  ## Example

      comp do
        # Extract any needed values from effects first
        config <- Reader.ask(:config)

        # CPU-bound work runs in parallel - thunk captures what it needs
        h1 <- FiberPool.task(fn -> expensive_cpu_work(config) end)
        h2 <- FiberPool.task(fn -> another_cpu_work(config) end)

        # Await results
        r1 <- FiberPool.await!(h1)
        r2 <- FiberPool.await!(h2)

        {r1, r2}
      end
  """
  @spec task((-> term()), keyword()) :: Comp.Types.computation()
  def task(thunk, opts \\ []) when is_function(thunk, 0) do
    Comp.effect(@sig, %TaskOp{thunk: thunk, opts: opts})
  end

  @doc """
  Await a single fiber's result.

  Suspends the current fiber until the target fiber completes.
  Returns `{:ok, value}` on success or `{:error, reason}` on failure.

  ## Example

      comp do
        h <- FiberPool.fiber(some_work())
        result <- FiberPool.await(h)
        case result do
          {:ok, value} -> # use value
          {:error, reason} -> # handle error
        end
      end
  """
  @spec await(Handle.t()) :: Comp.Types.computation()
  def await(handle) do
    Comp.effect(@sig, %Await{handle: handle, raising: false})
  end

  @doc """
  Await a single fiber's result, raising on error.

  Suspends the current fiber until the target fiber completes.
  Returns the result value directly, or raises if the fiber errored.

  ## Example

      comp do
        h <- FiberPool.fiber(some_work())
        value <- FiberPool.await!(h)  # raises on error
        # use value
      end
  """
  @spec await!(Handle.t()) :: Comp.Types.computation()
  def await!(handle) do
    Comp.effect(@sig, %Await{handle: handle, raising: true})
  end

  @doc """
  Await a fiber's result with single-consumer semantics.

  Like `await/1`, but removes the result from the completed map after retrieval.
  Use this when you know the fiber will only be awaited once, to enable
  garbage collection of the result.

  This is used internally by Channel.take_async for memory-efficient streaming.
  """
  @spec await_consume(Handle.t()) :: Comp.Types.computation()
  def await_consume(handle) do
    Comp.effect(@sig, %Await{handle: handle, raising: false, consume: true})
  end

  @doc """
  Await all fibers' results.

  Suspends until all fibers complete. Returns results in the same order
  as the input handles, each as `{:ok, value}` or `{:error, reason}`.
  """
  @spec await_all([Handle.t()]) :: Comp.Types.computation()
  def await_all(handles) do
    Comp.effect(@sig, %AwaitAll{handles: handles, raising: false})
  end

  @doc """
  Await all fibers' results, raising on any error.

  Suspends until all fibers complete. Returns result values in the same order
  as the input handles. Raises if any fiber errored.
  """
  @spec await_all!([Handle.t()]) :: Comp.Types.computation()
  def await_all!(handles) do
    Comp.effect(@sig, %AwaitAll{handles: handles, raising: true})
  end

  @doc """
  Await any fiber's result.

  Suspends until at least one fiber completes. Returns `{handle, result}`
  where result is `{:ok, value}` or `{:error, reason}`.
  """
  @spec await_any([Handle.t()]) :: Comp.Types.computation()
  def await_any(handles) do
    Comp.effect(@sig, %AwaitAny{handles: handles, raising: false})
  end

  @doc """
  Await any fiber's result, raising on error.

  Suspends until at least one fiber completes. Returns `{handle, value}`
  for the first fiber to complete. Raises if the fiber errored.
  """
  @spec await_any!([Handle.t()]) :: Comp.Types.computation()
  def await_any!(handles) do
    Comp.effect(@sig, %AwaitAny{handles: handles, raising: true})
  end

  @doc """
  Cancel a fiber.

  Marks the fiber for cancellation. If the fiber is suspended, it will
  be woken with an error. If running, it will be cancelled at the next
  suspension point.
  """
  @spec cancel(Handle.t()) :: Comp.Types.computation()
  def cancel(handle) do
    Comp.effect(@sig, %Cancel{handle: handle})
  end

  @doc """
  Create a structured concurrency scope.

  All fibers submitted within the scope will be awaited before the scope
  returns. If the scope body completes normally, all fibers are awaited
  and their results discarded (the scope returns the body's result).
  If the scope body errors, all fibers are cancelled.

  ## Options

  - `:on_exit` - Optional callback `fn result, handles -> computation()` called
    before awaiting fibers. Can be used for custom cleanup.

  ## Example

      FiberPool.scope(comp do
        h1 <- FiberPool.fiber(work1())
        h2 <- FiberPool.fiber(work2())
        # Both h1 and h2 will complete before scope exits
        FiberPool.await!(h1)
      end)
  """
  @spec scope(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def scope(comp, opts \\ []) do
    on_exit = Keyword.get(opts, :on_exit)
    Comp.effect(@sig, %Scope{comp: comp, on_exit: on_exit})
  end

  #############################################################################
  ## Combinators
  #############################################################################

  @doc """
  Spawn each computation as a fiber, returning all handles.

  The handles can be awaited individually or with `await_all/1` / `await_all!/1`.

  ## Example

      comp do
        handles <- FiberPool.fiber_all([fetch(:x), fetch(:y), fetch(:z)])
        FiberPool.await_all!(handles)
      end
  """
  @spec fiber_all([Comp.Types.computation()]) :: Comp.Types.computation()
  def fiber_all(comps) when is_list(comps) do
    fiber_all_acc(comps, [])
  end

  defp fiber_all_acc([], handles_acc) do
    Comp.pure(Enum.reverse(handles_acc))
  end

  defp fiber_all_acc([comp | rest], handles_acc) do
    Comp.bind(fiber(comp), fn handle ->
      fiber_all_acc(rest, [handle | handles_acc])
    end)
  end

  @doc """
  Run a list of computations concurrently as fibers, returning all results in order.

  Each computation is spawned as a fiber, then all are awaited with `await_all!/1`.
  Raises if any fiber fails.

  A single-element list is optimised to skip fiber overhead.

  This is the primitive used by the `query` macro for independent binding groups.

  ## Example

      FiberPool.spawn_await_all([fetch(:x), fetch(:y), fetch(:z)])
      # returns a computation producing [x_result, y_result, z_result]
  """
  @spec spawn_await_all([Comp.Types.computation()]) :: Comp.Types.computation()
  def spawn_await_all([single]) do
    # Optimization: single computation doesn't need fiber overhead
    Comp.bind(single, fn result -> Comp.pure([result]) end)
  end

  def spawn_await_all(comps) when is_list(comps) do
    Comp.bind(fiber_all(comps), fn handles ->
      await_all!(handles)
    end)
  end

  @doc """
  Applicative `ap` — run a function-producing computation and a value-producing
  computation concurrently as FiberPool fibers, then apply the function to
  the value.

  This is the standard applicative functor `<*>` operation. Both computations
  are spawned as cooperative fibers within the same FiberPool, so their effects
  (including data fetches) land in the same batch round, enabling implicit
  concurrency.

  Requires a `FiberPool` handler to be installed.

  ## Example

      comp_f = Comp.pure(fn x -> x * 2 end)
      comp_a = Comp.pure(21)
      result = FiberPool.ap(comp_f, comp_a)
      # result is a computation that returns 42
  """
  @spec ap(Comp.Types.computation(), Comp.Types.computation()) :: Comp.Types.computation()
  def ap(comp_f, comp_a) do
    Comp.bind(spawn_await_all([comp_f, comp_a]), fn [f, a] ->
      Comp.pure(f.(a))
    end)
  end

  @doc """
  Map a function over items, running each result computation as a fiber,
  and return all results in order.

  This is a convenience combining `Enum.map/2`, `fiber_all/1`, and `await_all!/1`.
  Raises if any fiber fails.

  ## Example

      FiberPool.map([1, 2, 3], &Queries.get_user/1)
      # returns a computation producing [user1, user2, user3]
  """
  @spec map([a], (a -> Comp.Types.computation())) :: Comp.Types.computation() when a: term()
  def map(items, fun) when is_list(items) and is_function(fun, 1) do
    items
    |> Enum.map(fun)
    |> spawn_await_all()
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install the FiberPool handler for a computation.

  The handler collects fiber submissions and await operations.
  Use `run/1` or `run!/1` to execute the computation with full
  fiber scheduling.
  """
  @spec with_handler(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def with_handler(comp, _opts \\ []) do
    comp
    |> Comp.with_scoped_state(PendingWork.env_key(), PendingWork.new())
    |> Comp.with_handler(@sig, &handle/3)
  end

  @doc """
  Install a Task.Supervisor for BEAM task support.

  This starts a `Task.Supervisor` process before the computation runs and
  stops it after completion. Required for `FiberPool.task/2` — calling
  `task/2` without this will raise an error.

  ## Example

      comp do
        h <- FiberPool.task(fn -> expensive_cpu_work() end)
        FiberPool.await!(h)
      end
      |> FiberPool.with_handler()
      |> FiberPool.with_task_supervisor()
      |> Comp.run!()

  ## Options

  - `:supervisor` - An existing `Task.Supervisor` pid to use instead of
    starting a new one. The caller is responsible for its lifecycle.
  """
  @task_supervisor_key {__MODULE__, :task_supervisor}

  @spec with_task_supervisor(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def with_task_supervisor(comp, opts \\ []) do
    Comp.scoped(comp, fn env ->
      {sup, should_stop} =
        case Keyword.get(opts, :supervisor) do
          nil ->
            {:ok, sup} = Task.Supervisor.start_link()
            {sup, true}

          sup when is_pid(sup) ->
            {sup, false}
        end

      modified_env = Env.put_state(env, @task_supervisor_key, sup)

      finally_k = fn value, final_env ->
        if should_stop do
          Supervisor.stop(sup)
        end

        {value, final_env}
      end

      {modified_env, finally_k}
    end)
  end

  @doc false
  def task_supervisor_key, do: @task_supervisor_key

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
      task_sup = Env.get_state(env, @task_supervisor_key)

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
  ## Handler Implementation
  #############################################################################

  defp handle(%FiberOp{comp: comp, opts: _opts}, env, k) do
    # Create a fiber for the computation
    pool_id = Env.get_state(env, {__MODULE__, :pool_id}, make_ref())

    # Clear pending work from the fiber's env to avoid inheriting parent's pending list
    # This prevents re-collecting the same fibers when the child runs
    fiber_env = Env.put_state(env, PendingWork.env_key(), PendingWork.new())
    fiber = Fiber.new(comp, fiber_env)
    handle = Handle.new(fiber.id, pool_id)

    # Add to pending fibers list (scheduler will pick them up)
    pending_work = Env.get_state(env, PendingWork.env_key(), PendingWork.new())
    pending_work = PendingWork.add_fiber(pending_work, fiber.id, fiber)
    env = Env.put_state(env, PendingWork.env_key(), pending_work)

    # Return handle immediately
    k.(handle, env)
  end

  defp handle(%Await{handle: handle, raising: raising, consume: consume}, env, k) do
    # Yield a FiberPool suspension for the scheduler to handle
    # Note: resume takes env as parameter to avoid capturing stale env with pending fibers
    resume = fn result, resume_env ->
      value = if raising, do: unwrap_result(result), else: result
      k.(value, resume_env)
    end

    suspend = InternalSuspend.await_one(handle, resume, consume: consume)
    {suspend, env}
  end

  defp handle(%AwaitAll{handles: handles, raising: raising}, env, k) do
    # Note: resume takes env as parameter to avoid capturing stale env with pending fibers
    resume = fn results, resume_env ->
      # Results is a list of {:ok, val} | {:error, reason}
      values =
        if raising do
          # Unwrap all, raising on first error
          Enum.map(results, &unwrap_result/1)
        else
          # Return result tuples as-is
          results
        end

      k.(values, resume_env)
    end

    suspend = InternalSuspend.await_all(handles, resume)
    {suspend, env}
  end

  defp handle(%AwaitAny{handles: handles, raising: raising}, env, k) do
    # Note: resume takes env as parameter to avoid capturing stale env with pending fibers
    resume = fn {fiber_id, result}, resume_env ->
      # Find the handle that completed
      handle = Enum.find(handles, &(&1.id == fiber_id))

      value =
        if raising do
          {handle, unwrap_result(result)}
        else
          {handle, result}
        end

      k.(value, resume_env)
    end

    suspend = InternalSuspend.await_any(handles, resume)
    {suspend, env}
  end

  defp handle(%Cancel{handle: handle}, env, k) do
    # Mark fiber for cancellation
    # The scheduler will handle actual cancellation
    cancelled = Env.get_state(env, {__MODULE__, :cancelled}, [])
    env = Env.put_state(env, {__MODULE__, :cancelled}, [handle.id | cancelled])

    k.(:ok, env)
  end

  defp handle(%TaskOp{thunk: thunk, opts: opts}, env, k) do
    # Create a unique handle_id for this task (like a fiber_id)
    handle_id = make_ref()
    pool_id = Env.get_state(env, {__MODULE__, :pool_id}, make_ref())
    handle = Handle.new(handle_id, pool_id)

    # Store pending task for the scheduler to spawn
    # We don't spawn here because we need the scheduler's Task.Supervisor
    pending_work = Env.get_state(env, PendingWork.env_key(), PendingWork.new())
    task_info = {handle_id, thunk, opts}
    pending_work = PendingWork.add_task(pending_work, task_info)
    env = Env.put_state(env, PendingWork.env_key(), pending_work)

    # Return handle immediately
    k.(handle, env)
  end

  defp handle(%Scope{comp: scoped_comp, on_exit: on_exit}, env, k) do
    # Capture current scope's fiber list
    scope_key = {__MODULE__, :scope_fibers, make_ref()}

    # Initialize scope's fiber tracking
    env = Env.put_state(env, scope_key, [])

    # Create wrapped computation that tracks fibers submitted in this scope
    wrapped =
      Comp.bind(scoped_comp, fn result ->
        # Get handles for fibers spawned in this scope
        fn inner_env, inner_k ->
          scope_handles = Env.get_state(inner_env, scope_key, [])

          # Call on_exit callback if provided
          after_exit =
            if on_exit do
              Comp.bind(on_exit.(result, scope_handles), fn _ ->
                Comp.pure(result)
              end)
            else
              Comp.pure(result)
            end

          # After on_exit, await all scope fibers (if any)
          final =
            if scope_handles == [] do
              after_exit
            else
              Comp.bind(after_exit, fn r ->
                # Await all fibers spawned in this scope
                Comp.bind(await_all(scope_handles), fn _results ->
                  Comp.pure(r)
                end)
              end)
            end

          Comp.call(final, inner_env, inner_k)
        end
      end)

    # Override the FiberOp handler to also track in scope
    scope_fiber_handler = fn
      %FiberOp{} = op, handler_env, handler_k ->
        # First do the normal fiber spawn
        {result, new_env} = handle(op, handler_env, &Comp.identity_k/2)

        # Track the handle in this scope
        case result do
          %Handle{} = h ->
            scope_handles = Env.get_state(new_env, scope_key, [])
            new_env = Env.put_state(new_env, scope_key, [h | scope_handles])
            handler_k.(h, new_env)

          other ->
            handler_k.(other, new_env)
        end

      other_op, handler_env, handler_k ->
        handle(other_op, handler_env, handler_k)
    end

    # Run wrapped with scope-aware handler
    inner_comp =
      wrapped
      |> Comp.with_handler(@sig, scope_fiber_handler)

    Comp.call(inner_comp, env, k)
  end

  # Unwrap a result, raising on error
  defp unwrap_result({:ok, value}), do: value

  defp unwrap_result({:error, reason}) do
    raise "Fiber failed: #{inspect(reason)}"
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
