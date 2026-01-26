defmodule Skuld.Effects.NonBlockingAsync do
  @moduledoc """
  Non-blocking async effect for cooperative multitasking.

  Provides two mechanisms for concurrent work:

  - **`async/1`** - Spawns an Erlang Task for parallel execution
  - **`fiber/1`** - Registers a computation for cooperative scheduling (no process spawned)

  Both can be mixed freely within a `boundary/2` and awaited using the same `await/1` function.

  ## Fiber vs Task

  | Operation | Execution Model | Process       | Use Case                      |
  |-----------|-----------------|---------------|-------------------------------|
  | `fiber/1` | Cooperative     | Same process  | CPU-bound work, complex state |
  | `async/1` | Parallel        | Separate Task | I/O-bound work, isolation     |

  **Fibers** run cooperatively in the scheduler process. They yield explicitly at `await`
  points, allowing other fibers to run. Good for CPU-bound work or when you need to share
  complex state without message passing.

  **Tasks** run in parallel in separate Erlang processes. Good for I/O-bound work or when
  you need process isolation for fault tolerance.

  ## Key Differences from Async Effect

  | Feature               | Async                | NonBlockingAsync            |
  |-----------------------|----------------------|-----------------------------|
  | `fiber/1`             | ❌                   | ✅ Cooperative scheduling   |
  | `async/1`             | Blocks on await      | ✅ Yields, non-blocking     |
  | `await_all/1`         | ❌                   | ✅                          |
  | `await_any/1`         | ❌                   | ✅                          |
  | Reusable timeouts     | ❌                   | ✅                          |
  | Multiple computations | ❌                   | ✅ (via Scheduler)          |
  | Use case              | Simple parallel work | Complex workflows, timeouts |

  ## Basic Usage

      use Skuld.Syntax
      alias Skuld.Comp
      alias Skuld.Effects.{NonBlockingAsync, Throw}
      alias Skuld.Effects.NonBlockingAsync.Scheduler

      comp do
        result <- NonBlockingAsync.boundary(comp do
          # Cooperative fibers - run in scheduler process
          h1 <- NonBlockingAsync.fiber(work1())
          h2 <- NonBlockingAsync.fiber(work2())

          # Or parallel tasks - run in separate processes
          h3 <- NonBlockingAsync.async(io_work())

          r1 <- NonBlockingAsync.await(h1)
          r2 <- NonBlockingAsync.await(h2)
          r3 <- NonBlockingAsync.await(h3)

          {r1, r2, r3}
        end)

        result
      end
      |> NonBlockingAsync.with_handler()
      |> Throw.with_handler()
      |> Scheduler.run_one()

  ## Simple Usage with `with_sequential_handler`

  For simpler cases (especially testing), use `with_sequential_handler/1`:

      comp do
        NonBlockingAsync.boundary(comp do
          h <- NonBlockingAsync.fiber(work())
          NonBlockingAsync.await(h)
        end)
      end
      |> NonBlockingAsync.with_sequential_handler()
      |> Comp.run!()

  ## Timeout Patterns

  Use `await_any` with a timer for timeout:

      timer = TimerTarget.new(5000)  # 5 second overall timeout

      h1 <- NonBlockingAsync.async(slow_work())

      # Race task against timer
      {target_key, result} <- NonBlockingAsync.await_any_raw([TaskTarget.new(h1.task), timer])
      case target_key do
        {:task, _} -> {:ok, result}
        {:timer, _} -> {:error, :timeout}
      end

  ## Cooperative Scheduling

  Run multiple computations cooperatively:

      Scheduler.run([
        user_workflow(user1),
        user_workflow(user2),
        user_workflow(user3)
      ])
  """

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Effects.Helpers.TaskHelpers
  alias Skuld.Effects.NonBlockingAsync.Await
  alias Skuld.Effects.NonBlockingAsync.AwaitRequest
  alias Skuld.Effects.NonBlockingAsync.AwaitRequest.FiberTarget
  alias Skuld.Effects.NonBlockingAsync.AwaitRequest.TaskTarget
  alias Skuld.Effects.NonBlockingAsync.Scheduler
  alias Skuld.Effects.Throw

  @sig __MODULE__

  #############################################################################
  ## Internal State Keys
  #############################################################################

  @supervisor_key {@sig, :supervisor}
  @boundaries_key {@sig, :boundaries}
  @current_boundary_key {@sig, :current_boundary}
  @pending_fibers_key {@sig, :pending_fibers}

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Async, [:comp])
  def_op(Fiber, [:comp])
  def_op(AwaitOp, [:handle])
  def_op(AwaitAll, [:handles])
  def_op(AwaitAny, [:handles])
  def_op(AwaitAnyRaw, [:targets])
  def_op(Cancel, [:handle])
  def_op(Boundary, [:comp, :on_unawaited])

  #############################################################################
  ## Handle Structures
  #############################################################################

  defmodule TaskHandle do
    @moduledoc """
    Handle for a parallel Task spawned via `async/1`.

    Contains the boundary it belongs to and the underlying Erlang Task.
    """
    @type t :: %__MODULE__{
            boundary_id: reference(),
            task: Task.t()
          }
    defstruct [:boundary_id, :task]
  end

  defmodule FiberHandle do
    @moduledoc """
    Handle for a cooperative fiber spawned via `fiber/1`.

    Contains the boundary it belongs to and a unique fiber ID.
    Fibers run cooperatively in the scheduler process, not as separate Erlang processes.
    """
    @type t :: %__MODULE__{
            boundary_id: reference(),
            fiber_id: reference()
          }
    defstruct [:boundary_id, :fiber_id]
  end

  # Union type for handles - either a TaskHandle or FiberHandle
  @type handle :: TaskHandle.t() | FiberHandle.t()

  #############################################################################
  ## Public Operations
  #############################################################################

  @doc """
  Start a computation as a parallel Task, returning a handle.

  Spawns an Erlang Task to run the computation in a separate process.
  Use this for I/O-bound work or when you need process isolation.

  For cooperative scheduling in the same process, use `fiber/1` instead.

  Must be called within a `boundary/2` scope. The handle can only
  be awaited within the same boundary.

  ## Example

      NonBlockingAsync.boundary(comp do
        # Runs in separate process
        handle <- NonBlockingAsync.async(io_work())
        # ... do other work ...
        result <- NonBlockingAsync.await(handle)
        result
      end)
  """
  @spec async(Types.computation()) :: Types.computation()
  def async(comp) do
    Comp.effect(@sig, %Async{comp: comp})
  end

  @doc """
  Start a computation as a cooperative fiber, returning a handle.

  Unlike `async/1` which spawns an Erlang Task (parallel execution),
  `fiber/1` registers the computation with the scheduler for cooperative
  execution in the same process. Fibers yield explicitly and are scheduled
  by the NonBlockingAsync scheduler.

  Must be called within a `boundary/2` scope. The handle can only
  be awaited within the same boundary.

  ## Example

      NonBlockingAsync.boundary(comp do
        # Cooperative fibers - run in scheduler process
        h1 <- NonBlockingAsync.fiber(work1())
        h2 <- NonBlockingAsync.fiber(work2())

        # Can mix with parallel tasks
        h3 <- NonBlockingAsync.async(parallel_work())

        r1 <- NonBlockingAsync.await(h1)
        r2 <- NonBlockingAsync.await(h2)
        r3 <- NonBlockingAsync.await(h3)
        {r1, r2, r3}
      end)
  """
  @spec fiber(Types.computation()) :: Types.computation()
  def fiber(comp) do
    Comp.effect(@sig, %Fiber{comp: comp})
  end

  @doc """
  Wait for an async computation or fiber to complete and return its result.

  Works with both `TaskHandle` (from `async/1`) and `FiberHandle` (from `fiber/1`).
  Unlike `Async.await/1`, this yields an `%AwaitSuspend{}` if the computation
  is not immediately ready, allowing other fibers and computations to run.

  Returns the unwrapped result directly. Errors are propagated.

  ## Example

      # Await a fiber
      fiber_handle <- NonBlockingAsync.fiber(cpu_work())
      result1 <- NonBlockingAsync.await(fiber_handle)

      # Await a task
      task_handle <- NonBlockingAsync.async(io_work())
      result2 <- NonBlockingAsync.await(task_handle)
  """
  @spec await(TaskHandle.t() | FiberHandle.t()) :: Types.computation()
  def await(%TaskHandle{} = handle) do
    Comp.effect(@sig, %AwaitOp{handle: handle})
  end

  def await(%FiberHandle{} = handle) do
    Comp.effect(@sig, %AwaitOp{handle: handle})
  end

  @doc """
  Wait for all async computations to complete.

  Returns results in the same order as the input handles.

  ## Example

      h1 <- NonBlockingAsync.async(work1())
      h2 <- NonBlockingAsync.async(work2())
      [r1, r2] <- NonBlockingAsync.await_all([h1, h2])
  """
  @spec await_all([TaskHandle.t() | FiberHandle.t()]) :: Types.computation()
  def await_all(handles) when is_list(handles) do
    Comp.effect(@sig, %AwaitAll{handles: handles})
  end

  @doc """
  Wait for any computation to complete.

  Works with both `TaskHandle` (from `async/1`) and `FiberHandle` (from `fiber/1`).
  Can mix fibers and tasks freely.

  Returns `{winning_handle, result}` for the first to complete.
  Other computations remain running and can be awaited or cancelled.

  ## Example

      # Race a fiber against a task
      h1 <- NonBlockingAsync.fiber(approach_a())
      h2 <- NonBlockingAsync.async(approach_b())
      {winner, result} <- NonBlockingAsync.await_any([h1, h2])

      # Cancel the loser if desired
      loser = if winner == h1, do: h2, else: h1
      _ <- NonBlockingAsync.cancel(loser)
  """
  @spec await_any([TaskHandle.t() | FiberHandle.t()]) :: Types.computation()
  def await_any(handles) when is_list(handles) do
    Comp.effect(@sig, %AwaitAny{handles: handles})
  end

  @doc """
  Wait for any of the raw targets to complete.

  This is the low-level API for awaiting heterogeneous targets
  (tasks, timers, computations). Returns `{target_key, result}`.

  Use this for timeout patterns with reusable timers:

      timer = TimerTarget.new(5000)
      h <- NonBlockingAsync.async(work())

      {target_key, result} <- NonBlockingAsync.await_any_raw([
        TaskTarget.new(h.task),
        timer
      ])

      case target_key do
        {:task, _} -> result
        {:timer, _} -> :timeout
      end
  """
  @spec await_any_raw([AwaitRequest.target()]) :: Types.computation()
  def await_any_raw(targets) when is_list(targets) do
    Comp.effect(@sig, %AwaitAnyRaw{targets: targets})
  end

  @doc """
  Cancel an async task before awaiting it.

  The task is terminated and removed from the boundary's unawaited set.
  Returns `:ok`. Cancelling an already-completed or already-cancelled task
  is a no-op.

  ## Example

      NonBlockingAsync.boundary(comp do
        h1 <- NonBlockingAsync.async(approach_a())
        h2 <- NonBlockingAsync.async(approach_b())

        # Use first result, cancel the other
        result <- NonBlockingAsync.await(h1)
        _ <- NonBlockingAsync.cancel(h2)
        result
      end)
  """
  @spec cancel(TaskHandle.t() | FiberHandle.t()) :: Types.computation()
  def cancel(%TaskHandle{} = handle) do
    Comp.effect(@sig, %Cancel{handle: handle})
  end

  def cancel(%FiberHandle{} = handle) do
    Comp.effect(@sig, %Cancel{handle: handle})
  end

  @doc """
  Establish a structured concurrency boundary.

  All async tasks started within this boundary must be awaited before
  the boundary exits. If tasks remain unawaited:

  1. All unawaited tasks are killed (non-negotiable)
  2. The `on_unawaited` function is called with `(result, unawaited_handles)`
  3. Its return value becomes the boundary's result

  By default, throws `{:unawaited_tasks, count}` if any tasks were unawaited.

  ## Examples

      # Default: error on unawaited
      NonBlockingAsync.boundary(comp do
        h <- NonBlockingAsync.async(work())
        # forgot await - will throw!
        :done
      end)

      # Custom: log warning, return result anyway
      NonBlockingAsync.boundary(
        comp do
          h <- NonBlockingAsync.async(fire_and_forget())
          :done
        end,
        fn result, unawaited ->
          Logger.warning("Killed \#{length(unawaited)} unawaited tasks")
          result
        end
      )
  """
  @spec boundary(Types.computation(), (term(), list(handle()) -> term()) | nil) ::
          Types.computation()
  def boundary(comp, on_unawaited \\ nil) do
    on_unawaited =
      on_unawaited ||
        fn _result, unawaited ->
          Throw.throw({:unawaited_tasks, length(unawaited)})
        end

    Comp.effect(@sig, %Boundary{comp: comp, on_unawaited: on_unawaited})
  end

  #############################################################################
  ## Handler
  #############################################################################

  @doc """
  Install the NonBlockingAsync handler.

  Creates a Task.Supervisor and sets up boundary tracking. The supervisor
  is stopped when the handler scope exits.

  Also installs the low-level Await handler automatically.

  ## Example

      comp do
        NonBlockingAsync.boundary(comp do
          h <- NonBlockingAsync.async(work())
          NonBlockingAsync.await(h)
        end)
      end
      |> NonBlockingAsync.with_handler()
      |> Throw.with_handler()
      |> Scheduler.run()
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(comp) do
    comp
    |> Await.with_handler()
    |> Comp.scoped(fn env ->
      {:ok, sup} = Task.Supervisor.start_link()

      modified =
        env
        |> Env.put_state(@supervisor_key, sup)
        |> Env.put_state(@boundaries_key, %{})
        |> Env.put_state(@current_boundary_key, nil)
        |> Env.put_state(@pending_fibers_key, [])

      finally_k = fn value, e ->
        sup = Env.get_state(e, @supervisor_key)
        TaskHelpers.stop_supervisor(sup)

        cleaned =
          %{
            e
            | state:
                e.state
                |> Map.delete(@supervisor_key)
                |> Map.delete(@boundaries_key)
                |> Map.delete(@current_boundary_key)
                |> Map.delete(@pending_fibers_key)
          }

        {value, cleaned}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &handle/3)
  end

  @doc """
  Run a computation with NonBlockingAsync effects handled sequentially.

  Wraps the computation with handlers and runs it through the cooperative
  scheduler. This is useful for testing where you want deterministic execution
  in a single process.

  All fibers run cooperatively in the current process (no parallelism).
  Tasks are still spawned but awaited through the scheduler.

  ## Example

      comp do
        result <- NonBlockingAsync.boundary(comp do
          h1 <- NonBlockingAsync.fiber(work1())
          h2 <- NonBlockingAsync.fiber(work2())
          r1 <- NonBlockingAsync.await(h1)
          r2 <- NonBlockingAsync.await(h2)
          {r1, r2}
        end)
        result
      end
      |> NonBlockingAsync.with_sequential_handler()
      |> Comp.run!()

  ## Differences from with_handler

  - `with_handler/1` - Returns a computation that must be run through `Scheduler.run_one`
  - `with_sequential_handler/1` - Returns a computation that can be run directly via `Comp.run!`

  ## Error Handling

  Errors from the computation are propagated via `Throw.throw/1`.
  """
  @spec with_sequential_handler(Types.computation()) :: Types.computation()
  def with_sequential_handler(comp) do
    fn env, k ->
      # Wrap in handlers and run through scheduler
      handled_comp =
        comp
        |> with_handler()
        |> Throw.with_handler()

      case Scheduler.run_one(handled_comp) do
        {:done, result} ->
          k.(result, env)

        {:error, reason} ->
          Comp.call(Throw.throw(reason), env, k)

        {:suspended, suspend, _resume_fn} ->
          # External yield - propagate as suspend
          {suspend, env}
      end
    end
  end

  @doc """
  Install NonBlockingAsync handler via catch clause syntax.

  Config selects handler type:

      catch
        NonBlockingAsync -> nil           # standard handler
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, nil), do: with_handler(comp)
  def __handle__(comp, :async), do: with_handler(comp)

  @impl Skuld.Comp.IHandle
  def handle(%Boundary{comp: inner_comp, on_unawaited: on_unawaited}, env, k) do
    # Generate unique boundary ID
    boundary_id = make_ref()

    # Use scoped to ensure cleanup happens on both normal and throw paths
    scoped_comp =
      inner_comp
      |> Comp.scoped(fn e ->
        # Setup: register boundary and set as current
        boundaries = Env.get_state(e, @boundaries_key)
        previous_boundary = Env.get_state(e, @current_boundary_key)

        modified =
          e
          |> Env.put_state(@boundaries_key, Map.put(boundaries, boundary_id, MapSet.new()))
          |> Env.put_state(@current_boundary_key, boundary_id)
          |> Env.put_state({@sig, :boundary_previous, boundary_id}, previous_boundary)

        finally_k = fn result, env_after ->
          # Get unawaited tasks for this boundary
          boundaries_after = Env.get_state(env_after, @boundaries_key)

          unawaited_handles =
            Map.get(boundaries_after, boundary_id, MapSet.new()) |> MapSet.to_list()

          prev_boundary = Env.get_state(env_after, {@sig, :boundary_previous, boundary_id})

          # Kill all unawaited tasks (non-negotiable)
          # Note: Only TaskHandles have actual tasks to kill. FiberHandles are cooperative
          # and don't need termination since they run in the same process.
          sup = Env.get_state(env_after, @supervisor_key)

          if sup do
            Enum.each(unawaited_handles, fn
              %TaskHandle{task: task} ->
                Task.Supervisor.terminate_child(sup, task.pid)

              %FiberHandle{} ->
                # Fibers don't need termination - they're in-process
                :ok
            end)
          end

          # Clean up boundary and restore previous
          env_cleaned =
            env_after
            |> Env.put_state(@boundaries_key, Map.delete(boundaries_after, boundary_id))
            |> Env.put_state(@current_boundary_key, prev_boundary)
            |> then(fn e2 ->
              %{e2 | state: Map.delete(e2.state, {@sig, :boundary_previous, boundary_id})}
            end)

          # For throws, just propagate (don't call on_unawaited)
          case result do
            %Comp.Throw{} ->
              {result, env_cleaned}

            _ ->
              # Normal completion - check for unawaited tasks
              case unawaited_handles do
                [] ->
                  {result, env_cleaned}

                _ ->
                  handler_result = on_unawaited.(result, unawaited_handles)

                  case handler_result do
                    fun when is_function(fun, 2) ->
                      # It's a computation - run it
                      Comp.call(fun, env_cleaned, fn v, e2 -> {v, e2} end)

                    value ->
                      {value, env_cleaned}
                  end
              end
          end
        end

        {modified, finally_k}
      end)

    # Run the scoped computation with our continuation
    Comp.call(scoped_comp, env, k)
  end

  def handle(%Async{comp: comp}, env, k) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if current_boundary == nil do
      # No boundary - throw error via Throw effect
      Comp.call(Throw.throw({:error, :async_outside_boundary}), env, k)
    else
      sup = Env.get_state(env, @supervisor_key)

      # Start task with snapshot of current env
      task =
        Task.Supervisor.async_nolink(sup, fn ->
          {result, _final_env} = Comp.call(comp, env, fn v, e -> {v, e} end)
          result
        end)

      # Create handle and track it
      handle = %TaskHandle{boundary_id: current_boundary, task: task}

      boundaries = Env.get_state(env, @boundaries_key)
      boundary_tasks = Map.get(boundaries, current_boundary, MapSet.new())
      updated_tasks = MapSet.put(boundary_tasks, handle)

      env_tracked =
        Env.put_state(env, @boundaries_key, Map.put(boundaries, current_boundary, updated_tasks))

      k.(handle, env_tracked)
    end
  end

  def handle(%Fiber{comp: comp}, env, k) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if current_boundary == nil do
      # No boundary - throw error via Throw effect
      Comp.call(Throw.throw({:error, :fiber_outside_boundary}), env, k)
    else
      # Generate unique fiber ID
      fiber_id = make_ref()

      # Create handle and track it in boundary
      handle = %FiberHandle{boundary_id: current_boundary, fiber_id: fiber_id}

      boundaries = Env.get_state(env, @boundaries_key)
      boundary_handles = Map.get(boundaries, current_boundary, MapSet.new())
      updated_handles = MapSet.put(boundary_handles, handle)

      env_tracked =
        Env.put_state(
          env,
          @boundaries_key,
          Map.put(boundaries, current_boundary, updated_handles)
        )

      # Store fiber in pending_fibers for scheduler to extract
      pending = Env.get_state(env_tracked, @pending_fibers_key, [])
      fiber_entry = {fiber_id, comp, current_boundary}
      env_with_fiber = Env.put_state(env_tracked, @pending_fibers_key, [fiber_entry | pending])

      # Continue immediately with handle - no yield!
      # The fiber will be extracted by the scheduler when this computation yields/completes
      k.(handle, env_with_fiber)
    end
  end

  def handle(
        %AwaitOp{handle: %TaskHandle{boundary_id: handle_boundary, task: task} = handle},
        env,
        k
      ) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if handle_boundary != current_boundary do
      Comp.call(Throw.throw({:error, :await_across_boundary}), env, k)
    else
      # Fast path - check if result message is already available
      # Use peek_task_result to avoid the race condition where DOWN message
      # arrives before the result message (Task.yield(task, 0) can return
      # {:exit, :normal} even when the task completed successfully)
      case peek_task_result(task) do
        {:ok, value} ->
          # Already done - continue immediately, no yield
          env_untracked = untrack_handle(env, handle)
          k.(value, env_untracked)

        :not_ready ->
          # Not ready - yield to scheduler via Await effect
          target = TaskTarget.new(task)
          request = AwaitRequest.new([target], :all)

          await_comp = Await.await(request)

          Comp.call(await_comp, env, fn [result], env2 ->
            env_untracked = untrack_handle(env2, handle)

            case result do
              {:ok, value} ->
                k.(value, env_untracked)

              {:error, reason} ->
                Comp.call(Throw.throw({:error, reason}), env_untracked, k)
            end
          end)
      end
    end
  end

  def handle(
        %AwaitOp{handle: %FiberHandle{boundary_id: handle_boundary, fiber_id: fiber_id} = handle},
        env,
        k
      ) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if handle_boundary != current_boundary do
      Comp.call(Throw.throw({:error, :await_across_boundary}), env, k)
    else
      # Fibers are always yielded to scheduler - no fast path check here
      # because fiber_results live in scheduler state, not in Env
      target = FiberTarget.new(fiber_id)
      request = AwaitRequest.new([target], :all)

      await_comp = Await.await(request)

      Comp.call(await_comp, env, fn [result], env2 ->
        env_untracked = untrack_handle(env2, handle)

        case result do
          {:ok, value} ->
            k.(value, env_untracked)

          {:error, reason} ->
            Comp.call(Throw.throw({:error, reason}), env_untracked, k)
        end
      end)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def handle(%AwaitAll{handles: handles}, env, k) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    # Verify all handles are from current boundary (TaskHandles only for now)
    invalid =
      Enum.find(handles, fn
        %TaskHandle{boundary_id: bid} -> bid != current_boundary
        %FiberHandle{boundary_id: bid} -> bid != current_boundary
      end)

    if invalid do
      Comp.call(Throw.throw({:error, :await_across_boundary}), env, k)
    else
      # Check fast path for all handles
      {ready_results, pending_handles} = check_ready(handles)

      case pending_handles do
        [] ->
          # All ready - return results immediately
          results = extract_results(handles, ready_results)
          env_untracked = Enum.reduce(handles, env, &untrack_handle(&2, &1))

          case results do
            {:ok, values} -> k.(values, env_untracked)
            {:error, reason} -> Comp.call(Throw.throw({:error, reason}), env_untracked, k)
          end

        _ ->
          # Some pending - yield to scheduler for ONLY the pending handles
          # (ready handles' messages were already consumed by check_ready)
          pending_targets = Enum.map(pending_handles, &handle_to_target/1)

          request = AwaitRequest.new(pending_targets, :all)

          await_comp = Await.await(request)

          Comp.call(await_comp, env, fn pending_results, env2 ->
            env_untracked = Enum.reduce(handles, env2, &untrack_handle(&2, &1))

            # Build map from target key to result for pending handles
            pending_results_map =
              pending_handles
              |> Enum.zip(pending_results)
              |> Enum.map(fn {handle, result} -> {handle_to_target_key(handle), result} end)
              |> Map.new()

            # Merge ready_results (from check_ready) with pending_results (from scheduler)
            # Return in original handle order
            all_results =
              Enum.map(handles, fn handle ->
                case Map.get(ready_results, handle) do
                  nil -> Map.fetch!(pending_results_map, handle_to_target_key(handle))
                  result -> result
                end
              end)

            case extract_all_results(all_results) do
              {:ok, values} -> k.(values, env_untracked)
              {:error, reason} -> Comp.call(Throw.throw({:error, reason}), env_untracked, k)
            end
          end)
      end
    end
  end

  def handle(%AwaitAny{handles: handles}, env, k) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    # Verify all handles are from current boundary
    invalid =
      Enum.find(handles, fn
        %TaskHandle{boundary_id: bid} -> bid != current_boundary
        %FiberHandle{boundary_id: bid} -> bid != current_boundary
      end)

    if invalid do
      Comp.call(Throw.throw({:error, :await_across_boundary}), env, k)
    else
      # Check fast path - any handle already ready?
      case find_ready(handles) do
        {:ready, handle, result} ->
          # Found a ready one
          env_untracked = untrack_handle(env, handle)

          case result do
            {:ok, value} -> k.({handle, value}, env_untracked)
            {:error, reason} -> Comp.call(Throw.throw({:error, reason}), env_untracked, k)
          end

        :none_ready ->
          # None ready - yield to scheduler
          targets = Enum.map(handles, &handle_to_target/1)
          request = AwaitRequest.new(targets, :any)

          await_comp = Await.await(request)

          Comp.call(await_comp, env, fn {target_key, result}, env2 ->
            # Find the handle that matches the target_key
            winning_handle = find_handle_by_target_key(handles, target_key)
            env_untracked = untrack_handle(env2, winning_handle)

            case result do
              {:ok, value} -> k.({winning_handle, value}, env_untracked)
              {:error, reason} -> Comp.call(Throw.throw({:error, reason}), env_untracked, k)
            end
          end)
      end
    end
  end

  def handle(%AwaitAnyRaw{targets: targets}, env, k) do
    # Low-level: await raw targets directly
    # No boundary checking (targets might not be from handles)
    request = AwaitRequest.new(targets, :any)
    await_comp = Await.await(request)

    Comp.call(await_comp, env, fn {target_key, result}, env2 ->
      k.({target_key, result}, env2)
    end)
  end

  def handle(
        %Cancel{handle: %TaskHandle{boundary_id: handle_boundary, task: task} = handle},
        env,
        k
      ) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if handle_boundary != current_boundary do
      Comp.call(Throw.throw({:error, :cancel_across_boundary}), env, k)
    else
      # Terminate the task
      sup = Env.get_state(env, @supervisor_key)

      if sup && Process.alive?(task.pid) do
        Task.Supervisor.terminate_child(sup, task.pid)
      end

      # Untrack the handle
      env_untracked = untrack_handle(env, handle)
      k.(:ok, env_untracked)
    end
  end

  def handle(
        %Cancel{handle: %FiberHandle{boundary_id: handle_boundary, fiber_id: fiber_id} = handle},
        env,
        k
      ) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if handle_boundary != current_boundary do
      Comp.call(Throw.throw({:error, :cancel_across_boundary}), env, k)
    else
      # Remove fiber from pending_fibers if it hasn't been extracted yet
      pending = Env.get_state(env, @pending_fibers_key, [])
      updated_pending = Enum.reject(pending, fn {fid, _comp, _bid} -> fid == fiber_id end)
      env_updated = Env.put_state(env, @pending_fibers_key, updated_pending)

      # Untrack the handle from boundary
      env_untracked = untrack_handle(env_updated, handle)
      k.(:ok, env_untracked)
    end
  end

  #############################################################################
  ## Helpers
  #############################################################################

  defp untrack_handle(env, handle) do
    boundary_id = get_boundary_id(handle)
    boundaries = Env.get_state(env, @boundaries_key)
    boundary_tasks = Map.get(boundaries, boundary_id, MapSet.new())
    updated_tasks = MapSet.delete(boundary_tasks, handle)
    Env.put_state(env, @boundaries_key, Map.put(boundaries, boundary_id, updated_tasks))
  end

  defp get_boundary_id(%TaskHandle{boundary_id: bid}), do: bid
  defp get_boundary_id(%FiberHandle{boundary_id: bid}), do: bid

  # Convert a handle to an await target
  defp handle_to_target(%TaskHandle{task: task}), do: TaskTarget.new(task)
  defp handle_to_target(%FiberHandle{fiber_id: fiber_id}), do: FiberTarget.new(fiber_id)

  # Get the target key for a handle (used for result correlation)
  defp handle_to_target_key(%TaskHandle{task: %Task{ref: ref}}), do: {:task, ref}
  defp handle_to_target_key(%FiberHandle{fiber_id: fiber_id}), do: {:fiber, fiber_id}

  # Check which handles have result messages already available.
  # Uses peek_task_result to avoid race condition with DOWN messages.
  # Note: Currently only works for TaskHandles. FiberHandle support will be added later.
  defp check_ready(handles) do
    Enum.reduce(handles, {%{}, []}, fn
      %TaskHandle{task: task} = handle, {ready, pending} ->
        case peek_task_result(task) do
          {:ok, value} ->
            {Map.put(ready, handle, {:ok, value}), pending}

          :not_ready ->
            {ready, [handle | pending]}
        end

      %FiberHandle{} = handle, {ready, pending} ->
        # FiberHandles are always pending - scheduler checks fiber_results
        {ready, [handle | pending]}
    end)
    |> then(fn {ready, pending} -> {ready, Enum.reverse(pending)} end)
  end

  # Extract results in handle order from ready map
  defp extract_results(handles, ready_results) do
    results = Enum.map(handles, &Map.fetch!(ready_results, &1))

    case Enum.find(results, fn
           {:error, _} -> true
           _ -> false
         end) do
      nil -> {:ok, Enum.map(results, fn {:ok, v} -> v end)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Extract values from scheduler results list
  defp extract_all_results(results) do
    case Enum.find(results, fn
           {:error, _} -> true
           _ -> false
         end) do
      nil -> {:ok, Enum.map(results, fn {:ok, v} -> v end)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Find first ready handle (has result message available).
  # Uses peek_task_result to avoid race condition with DOWN messages.
  # Note: Currently only works for TaskHandles. FiberHandle support will be added later.
  defp find_ready(handles) do
    Enum.find_value(handles, :none_ready, fn
      %TaskHandle{task: task} = handle ->
        case peek_task_result(task) do
          {:ok, value} ->
            {:ready, handle, {:ok, value}}

          :not_ready ->
            nil
        end

      %FiberHandle{} ->
        # FiberHandles are always pending - scheduler checks fiber_results
        nil
    end)
  end

  # Peek for task result message without consuming DOWN messages.
  # This avoids the race condition where Task.yield(task, 0) returns
  # {:exit, :normal} because the DOWN message arrived before the result message.
  # The scheduler handles this properly by waiting for both messages.
  defp peek_task_result(%Task{ref: ref}) do
    receive do
      {^ref, result} ->
        # Got the result - demonitor and flush any DOWN message
        Process.demonitor(ref, [:flush])
        {:ok, result}
    after
      0 -> :not_ready
    end
  end

  # Find handle by target key (task ref or fiber id)
  defp find_handle_by_target_key(handles, {:task, ref}) do
    Enum.find(handles, fn
      %TaskHandle{task: %Task{ref: task_ref}} -> task_ref == ref
      %FiberHandle{} -> false
    end)
  end

  defp find_handle_by_target_key(handles, {:fiber, fiber_id}) do
    Enum.find(handles, fn
      %FiberHandle{fiber_id: fid} -> fid == fiber_id
      %TaskHandle{} -> false
    end)
  end
end
