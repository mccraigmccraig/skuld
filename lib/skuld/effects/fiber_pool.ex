defmodule Skuld.Effects.FiberPool do
  @moduledoc """
  Effect for cooperative fiber-based concurrency.

  FiberPool provides lightweight cooperative concurrency within a single process.
  Fibers are scheduled cooperatively - they run until they await, complete, or error.

  ## Basic Usage

      comp do
        # Submit work as a fiber
        h1 <- FiberPool.submit(expensive_computation())
        h2 <- FiberPool.submit(another_computation())

        # Do other work while fibers run...

        # Await results
        r1 <- FiberPool.await(h1)
        r2 <- FiberPool.await(h2)

        {r1, r2}
      end
      |> FiberPool.with_handler()
      |> FiberPool.run()

  ## Structured Concurrency

  Use `scope/1` to ensure all spawned fibers complete before exiting:

      comp do
        FiberPool.scope(comp do
          h1 <- FiberPool.submit(work1())
          h2 <- FiberPool.submit(work2())
          # Both h1 and h2 will complete (or be cancelled) before scope exits
          FiberPool.await_all([h1, h2])
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
  alias Skuld.Fiber
  alias Skuld.Fiber.Handle
  alias Skuld.Fiber.FiberPool.State
  alias Skuld.Fiber.FiberPool.Scheduler
  alias Skuld.Fiber.FiberPool.Suspend, as: FPSuspend

  @sig __MODULE__

  #############################################################################
  ## Operations
  #############################################################################

  defmodule Submit do
    @moduledoc false
    defstruct [:comp, :opts]
  end

  defmodule Await do
    @moduledoc false
    defstruct [:handle]
  end

  defmodule AwaitAll do
    @moduledoc false
    defstruct [:handles]
  end

  defmodule AwaitAny do
    @moduledoc false
    defstruct [:handles]
  end

  defmodule Cancel do
    @moduledoc false
    defstruct [:handle]
  end

  defmodule Scope do
    @moduledoc false
    defstruct [:comp, :on_exit]
  end

  #############################################################################
  ## Public API
  #############################################################################

  @doc """
  Submit a computation to run as a fiber.

  Returns a handle that can be used to await the result.

  ## Options

  - `:priority` - Fiber priority (future use)
  """
  @spec submit(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def submit(computation, opts \\ []) do
    Comp.effect(@sig, %Submit{comp: computation, opts: opts})
  end

  @doc """
  Await a single fiber's result.

  Suspends the current fiber until the target fiber completes.
  Returns the result value directly, or raises if the fiber errored.
  """
  @spec await(Handle.t()) :: Comp.Types.computation()
  def await(handle) do
    Comp.effect(@sig, %Await{handle: handle})
  end

  @doc """
  Await all fibers' results.

  Suspends until all fibers complete. Returns results in the same order
  as the input handles.
  """
  @spec await_all([Handle.t()]) :: Comp.Types.computation()
  def await_all(handles) do
    Comp.effect(@sig, %AwaitAll{handles: handles})
  end

  @doc """
  Await any fiber's result.

  Suspends until at least one fiber completes. Returns `{handle, result}`
  for the first fiber to complete.
  """
  @spec await_any([Handle.t()]) :: Comp.Types.computation()
  def await_any(handles) do
    Comp.effect(@sig, %AwaitAny{handles: handles})
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
        h1 <- FiberPool.submit(work1())
        h2 <- FiberPool.submit(work2())
        # Both h1 and h2 will complete before scope exits
        FiberPool.await(h1)
      end)
  """
  @spec scope(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def scope(comp, opts \\ []) do
    on_exit = Keyword.get(opts, :on_exit)
    Comp.effect(@sig, %Scope{comp: comp, on_exit: on_exit})
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @state_key {__MODULE__, :pending_fibers}

  @doc """
  Install the FiberPool handler for a computation.

  The handler collects fiber submissions and await operations.
  Use `run/1` or `run!/1` to execute the computation with full
  fiber scheduling.
  """
  @spec with_handler(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def with_handler(comp, _opts \\ []) do
    comp
    |> Comp.with_scoped_state(@state_key, [])
    |> Comp.with_handler(@sig, &handle/3)
  end

  @doc """
  Run a computation with FiberPool scheduling.

  This is the main entry point. It:
  1. Runs the main computation
  2. Schedules any spawned fibers
  3. Returns when all fibers complete
  """
  @spec run(Comp.Types.computation()) :: {term(), Comp.Types.env()}
  def run(comp) do
    env = Env.new()
    state = State.new()

    {result, env} = Comp.call(comp, env, &Comp.identity_k/2)

    # Extract pending fibers from env
    pending_fibers = Env.get_state(env, @state_key, [])

    if pending_fibers == [] and not is_struct(result, FPSuspend) do
      # No fibers spawned, simple completion
      {result, env}
    else
      # Run fibers
      run_with_fibers(state, env, result, pending_fibers)
    end
  end

  @doc """
  Run a computation with FiberPool scheduling, extracting the result.

  Raises if the result is a suspension or error sentinel.
  """
  @spec run!(Comp.Types.computation()) :: term()
  def run!(comp) do
    {result, _env} = run(comp)
    Comp.ISentinel.run!(result)
  end

  #############################################################################
  ## Handler Implementation
  #############################################################################

  defp handle(%Submit{comp: comp, opts: _opts}, env, k) do
    # Create a fiber for the computation
    pool_id = Env.get_state(env, {__MODULE__, :pool_id}, make_ref())
    fiber = Fiber.new(comp, env)
    handle = Handle.new(fiber.id, pool_id)

    # Add to pending fibers list (scheduler will pick them up)
    pending = Env.get_state(env, @state_key, [])
    env = Env.put_state(env, @state_key, [{fiber.id, fiber} | pending])

    # Return handle immediately
    k.(handle, env)
  end

  defp handle(%Await{handle: handle}, env, k) do
    # Yield a FiberPool suspension for the scheduler to handle
    resume = fn result -> k.(unwrap_result(result), env) end

    suspend = FPSuspend.await_one(handle, resume)
    {suspend, env}
  end

  defp handle(%AwaitAll{handles: handles}, env, k) do
    resume = fn results ->
      # Results is a list of {:ok, val} | {:error, reason}
      # Unwrap all, raising on first error
      values = Enum.map(results, &unwrap_result/1)
      k.(values, env)
    end

    suspend = FPSuspend.await_all(handles, resume)
    {suspend, env}
  end

  defp handle(%AwaitAny{handles: handles}, env, k) do
    resume = fn {fiber_id, result} ->
      # Find the handle that completed
      handle = Enum.find(handles, &(&1.id == fiber_id))
      k.({handle, unwrap_result(result)}, env)
    end

    suspend = FPSuspend.await_any(handles, resume)
    {suspend, env}
  end

  defp handle(%Cancel{handle: handle}, env, k) do
    # Mark fiber for cancellation
    # The scheduler will handle actual cancellation
    cancelled = Env.get_state(env, {__MODULE__, :cancelled}, [])
    env = Env.put_state(env, {__MODULE__, :cancelled}, [handle.id | cancelled])

    k.(:ok, env)
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

    # Override the Submit handler to also track in scope
    scope_submit_handler = fn
      %Submit{} = op, handler_env, handler_k ->
        # First do the normal submit
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
      |> Comp.with_handler(@sig, scope_submit_handler)

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

  defp run_with_fibers(state, env, main_result, pending_fibers) do
    # Add pending fibers to state
    state =
      Enum.reduce(pending_fibers, state, fn {_id, fiber}, acc ->
        {_id, acc} = State.add_fiber(acc, fiber)
        acc
      end)

    # If main result is a suspension, we need to handle it specially
    case main_result do
      %FPSuspend{} = suspend ->
        # Main computation is awaiting - need to run fibers and handle await
        run_scheduler_loop(state, env, {:awaiting, suspend})

      result ->
        # Main computation completed - just run remaining fibers
        case Scheduler.run(state, env) do
          {:done, _results, _final_state} ->
            {result, env}

          {:suspended, _fiber, _state} ->
            # External suspension - shouldn't happen without Task integration
            {result, env}

          {:error, reason, _state} ->
            {{:error, reason}, env}
        end
    end
  end

  # Run scheduler loop, handling FiberPool suspensions
  defp run_scheduler_loop(state, env, status) do
    case status do
      {:awaiting, %FPSuspend{handles: handles, mode: mode, resume: resume}} ->
        # Convert handles to fiber_ids
        fiber_ids = Enum.map(handles, & &1.id)

        # Get the fiber that is awaiting (we need to track which fiber this is)
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

      {:completed, result} ->
        {result, env}
    end
  end

  defp run_until_await_satisfied(state, env, awaiter_id, resume, mode) do
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
        # All fibers done - check if our await was satisfied
        {wake_result, state} = State.pop_wake_result(state, awaiter_id)

        case wake_result do
          nil ->
            # Await was never satisfied - this is an error
            {{:error, :await_never_satisfied}, env}

          result ->
            handle_await_result(state, env, result, resume, mode)
        end

      {:suspended, _fiber, _state} ->
        # A fiber yielded externally - for now, treat as error
        # (Task integration will handle this properly)
        {{:error, :external_suspension}, env}

      # Reserved for future error handling
      # {:error, reason, _state} ->
      #   {{:error, reason}, env}
    end
  end

  defp handle_await_result(state, _env, result, resume, mode) do
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

    # Resume the main computation
    {new_result, new_env} = resume.(unwrapped)

    # Check if we got another suspension
    case new_result do
      %FPSuspend{} = suspend ->
        run_scheduler_loop(state, new_env, {:awaiting, suspend})

      _ ->
        # Main computation completed - run any remaining fibers
        case Scheduler.run(state, new_env) do
          {:done, _results, _final_state} ->
            {new_result, new_env}

          {:suspended, _fiber, _state} ->
            {new_result, new_env}

          {:error, reason, _state} ->
            {{:error, reason}, new_env}
        end
    end
  end
end
