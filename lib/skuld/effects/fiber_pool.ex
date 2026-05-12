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
  alias Skuld.Fiber
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Fiber.Handle
  alias Skuld.Fiber.FiberPool.Main, as: FiberPoolMain
  alias Skuld.Fiber.FiberPool.PendingWork
  alias Skuld.Effects.Throw

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

  defmodule Scope do
    @moduledoc false
    defstruct [:comp, :on_exit]
  end

  #############################################################################
  ## Result types for await errors
  #############################################################################

  defmodule AwaitError do
    @moduledoc """
    Structured error for a single fiber/task failure.

    Thrown via `Throw.throw/1` when `await!/1` encounters a failed fiber.

    ## Fields

    - `:type` - The kind of failure: `:exception`, `:throw`, `:exit`, or `:cancelled`
    - `:error` - The original error value (exception struct, throw value, exit reason, etc.)
    - `:stacktrace` - The stacktrace if available, or `nil`
    """
    @type t :: %__MODULE__{
            type: :exception | :throw | :exit | :cancelled,
            error: term(),
            stacktrace: list() | nil
          }

    @derive Jason.Encoder
    defstruct [:type, :error, :stacktrace]
  end

  defmodule AwaitOk do
    @moduledoc """
    Successful result wrapper used only inside `AwaitAllResults.results`.

    Not returned from single `await!/1` — only used to distinguish successes
    from failures in a mixed-result `await_all!/1`.

    ## Fields

    - `:result` - The successful value
    """
    @type t :: %__MODULE__{result: term()}

    @derive Jason.Encoder
    defstruct [:result]
  end

  defmodule AwaitAllResults do
    @moduledoc """
    Mixed bag of results from `await_all!/1` when at least one fiber failed.

    Thrown via `Throw.throw/1` when `await_all!/1` encounters any failures.
    Contains the full list of results (both successes and failures) in the
    same order as the input handles.

    ## Fields

    - `:results` - List of `AwaitOk.t()` | `AwaitError.t()` in handle order
    """
    @type t :: %__MODULE__{results: [AwaitOk.t() | AwaitError.t()]}

    @derive Jason.Encoder
    defstruct [:results]
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

      FiberPool.fiber_await_all([fetch(:x), fetch(:y), fetch(:z)])
      # returns a computation producing [x_result, y_result, z_result]
  """
  @spec fiber_await_all([Comp.Types.computation()]) :: Comp.Types.computation()
  def fiber_await_all([single]) do
    # Optimization: single computation doesn't need fiber overhead
    Comp.bind(single, fn result -> Comp.pure([result]) end)
  end

  def fiber_await_all(comps) when is_list(comps) do
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

  ## How it achieves concurrency

  `ap` runs exactly two computations concurrently: one that produces a
  function, and one that produces a value. Both are spawned as fibers and
  awaited together, so their data fetches land in the same batch round.
  When both complete, the function is applied to the value.

  To run more than two operations concurrently, `ap` is applied repeatedly
  (like cons building a list). Each application adds one more concurrent
  computation by pairing it with a function that accumulates results:

      # Three concurrent fetches via repeated ap:
      ap(
        ap(
          Comp.map(fetch(:x), fn x -> fn y -> [y, x] end end),
          fetch(:y)
        ),
        fetch(:z)
      )
      |> Comp.map(fn [z, y, x] -> {x, y, z} end)

  Each `ap` spawns two fibers — the accumulated computation so far (which
  returns a function) and the next value computation. The function captures
  previous results in a closure and conses the new value onto them. This is
  the standard applicative pattern from Haskell's `<*>`, where `liftA2`,
  `liftA3`, etc. are built by chaining `<*>` with `fmap`.

  In practice, the `query` macro handles this desugaring automatically —
  users rarely need to call `ap` directly.

  Requires a `FiberPool` handler to be installed.

  ## Example

      comp_f = Comp.pure(fn x -> x * 2 end)
      comp_a = Comp.pure(21)
      result = FiberPool.ap(comp_f, comp_a)
      # result is a computation that returns 42
  """
  @spec ap(Comp.Types.computation(), Comp.Types.computation()) :: Comp.Types.computation()
  def ap(comp_f, comp_a) do
    Comp.bind(fiber_await_all([comp_f, comp_a]), fn [f, a] ->
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
    |> fiber_await_all()
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
    # When the main computation completes normally (not via sentinel), drain
    # any pending fire-and-forget fibers (spawned but not awaited) while still
    # inside the handler chain. This ensures their effects (Writer.tell,
    # State.put, etc.) execute while outer scoped handlers are still active
    # and their state is still live.
    #
    # For InternalSuspend (Await, Batch, Channel), this bind does NOT fire —
    # sentinels propagate through bind without calling continuations. Those
    # are handled by InternalSuspend's ISentinel.run implementation, which
    # calls drain_pending at the Comp.run boundary.
    drain_comp =
      Comp.bind(comp, fn result ->
        fn env, k ->
          {drained_result, drained_env} = FiberPoolMain.drain_pending(result, env)
          k.(drained_result, drained_env)
        end
      end)

    drain_comp
    |> Comp.with_scoped_state(PendingWork.env_key(), PendingWork.new())
    |> Comp.with_handler(@sig, &handle/3)
  end

  #############################################################################
  ## Handler Implementation
  #############################################################################

  defp handle(%FiberOp{comp: comp, opts: _opts}, env, k) do
    # Create a fiber for the computation
    pool_id = Env.get_state(env, {__MODULE__, :pool_id}, make_ref())

    fiber_env = fiber_env(env)
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
      if raising do
        case unwrap_result(result) do
          {:ok, value} -> k.(value, resume_env)
          {:throw, sentinel} -> {sentinel, resume_env}
        end
      else
        k.(result, resume_env)
      end
    end

    suspend = InternalSuspend.await_one(handle, resume, consume: consume)
    {suspend, env}
  end

  defp handle(%AwaitAll{handles: handles, raising: raising}, env, k) do
    # Note: resume takes env as parameter to avoid capturing stale env with pending fibers
    resume = fn results, resume_env ->
      if raising do
        unwrapped = Enum.map(results, &unwrap_result/1)
        has_errors = Enum.any?(unwrapped, &match?({:throw, _}, &1))

        if has_errors do
          # Build mixed bag of AwaitOk / AwaitError for all results
          mixed =
            Enum.map(unwrapped, fn
              {:ok, value} -> %AwaitOk{result: value}
              {:throw, %Comp.Throw{error: await_error}} -> await_error
            end)

          sentinel = %Comp.Throw{error: %AwaitAllResults{results: mixed}}
          {sentinel, resume_env}
        else
          # All succeeded — unwrap values
          values = Enum.map(unwrapped, fn {:ok, value} -> value end)
          k.(values, resume_env)
        end
      else
        # Return result tuples as-is
        k.(results, resume_env)
      end
    end

    suspend = InternalSuspend.await_all(handles, resume)
    {suspend, env}
  end

  defp handle(%AwaitAny{handles: handles, raising: raising}, env, k) do
    # Note: resume takes env as parameter to avoid capturing stale env with pending fibers
    resume = fn {fiber_id, result}, resume_env ->
      # Find the handle that completed
      handle = Enum.find(handles, &(&1.id == fiber_id))

      if raising do
        case unwrap_result(result) do
          {:ok, value} -> k.({handle, value}, resume_env)
          {:throw, sentinel} -> {sentinel, resume_env}
        end
      else
        k.({handle, result}, resume_env)
      end
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

  defp handle(%Scope{comp: scoped_comp, on_exit: on_exit}, env, k) do
    {env, scope_key} = setup_scope(env)

    guarded_comp = wrap_scope_body(scoped_comp, scope_key, on_exit)
    scoped = Comp.with_handler(guarded_comp, @sig, tracker_handler(scope_key))

    Comp.call(scoped, env, k)
  end

  # Initialise scope tracking state in env.
  defp setup_scope(env) do
    scope_key = {__MODULE__, :scope_fibers, make_ref()}
    env = Env.put_state(env, scope_key, [])
    {env, scope_key}
  end

  # Wrap scope body with structured concurrency guarantees:
  # - Error path: cancel all scope fibers, re-throw
  # - Success path: run on_exit (if any), await all scope fibers, return body result
  defp wrap_scope_body(comp, scope_key, on_exit) do
    Throw.catch_error(comp, fn error ->
      fn err_env, err_k ->
        scope_handles = Env.get_state(err_env, scope_key, [])

        cancel_and_rethrow =
          Comp.bind(cancel_all(scope_handles), fn _ ->
            Throw.throw(error)
          end)

        Comp.call(cancel_and_rethrow, err_env, err_k)
      end
    end)
    |> then(fn guarded ->
      Comp.bind(guarded, fn result ->
        fn inner_env, inner_k ->
          scope_handles = Env.get_state(inner_env, scope_key, [])

          after_exit =
            if on_exit do
              Comp.bind(on_exit.(result, scope_handles), fn _ -> Comp.pure(result) end)
            else
              Comp.pure(result)
            end

          final =
            if scope_handles == [] do
              after_exit
            else
              Comp.bind(after_exit, fn r ->
                Comp.bind(await_all(scope_handles), fn _results -> Comp.pure(r) end)
              end)
            end

          Comp.call(final, inner_env, inner_k)
        end
      end)
    end)
  end

  # Handler wrapper that intercepts FiberOp to track spawned fibers in scope.
  defp tracker_handler(scope_key) do
    fn
      %FiberOp{} = op, handler_env, handler_k ->
        {result, new_env} = handle(op, handler_env, &Comp.identity_k/2)

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
  end

  # Cancel a list of handles sequentially
  defp cancel_all([]), do: Comp.pure(:ok)

  defp cancel_all([handle | rest]) do
    Comp.bind(cancel(handle), fn _ -> cancel_all(rest) end)
  end

  # Prepare an env for a new fiber: inherit evidence (handlers) and state,
  # but reset leave_scope and transform_suspend to identity — the fiber is
  # an independent execution context whose scope chain starts fresh.
  # Also clears pending work to avoid inheriting the parent's pending list.
  defp fiber_env(env) do
    env
    |> Env.put_state(PendingWork.env_key(), PendingWork.new())
    |> Env.with_leave_scope(&Comp.identity_k/2)
    |> Env.with_transform_suspend(&Comp.identity_k/2)
  end

  # Unwrap a fiber result into {:ok, value} or {:throw, %Comp.Throw{error: %AwaitError{}}}
  # The :throw variant is a Throw sentinel — resume lambdas return it directly
  # (bypassing the continuation k) so it flows through the leave_scope chain
  # where Throw.catch_error can intercept it.
  defp unwrap_result({:ok, value}), do: {:ok, value}

  defp unwrap_result(
         {:error, %Skuld.Fiber.Error{type: type, error: error, stacktrace: stacktrace}}
       ) do
    {:throw,
     %Comp.Throw{
       error: %AwaitError{type: type, error: error, stacktrace: stacktrace}
     }}
  end
end
