defmodule Skuld.Effects.Async do
  @moduledoc """
  Async effect - structured concurrency with async/await semantics.

  Provides asynchronous computation with explicit boundaries that ensure
  tasks cannot leak. All async tasks must be awaited before their boundary
  exits, or they are killed.

  ## Structured Concurrency

  The key principle is that child tasks cannot outlive their parent scope:

  1. `boundary/2` establishes a structured concurrency scope
  2. `async/1` starts a task within the current boundary
  3. `await/1` waits for a task result
  4. When a boundary exits, all unawaited tasks are killed

  ## Basic Usage

      use Skuld.Syntax
      alias Skuld.Comp
      alias Skuld.Effects.{Async, Throw}

      comp do
        result <- Async.boundary(comp do
          h1 <- Async.async(work1())
          h2 <- Async.async(work2())

          r1 <- Async.await(h1)
          r2 <- Async.await(h2)

          {r1, r2}
        end)

        result
      end
      |> Async.with_handler()
      |> Throw.with_handler()
      |> Comp.run!()

  ## Unawaited Task Handling

  By default, unawaited tasks cause an error. You can customize this:

      # Log warning but return result anyway
      Async.boundary(
        my_comp,
        fn result, unawaited ->
          Logger.warning("Killed \#{length(unawaited)} tasks")
          result
        end
      )

      # Wrap result with metadata
      Async.boundary(my_comp, fn result, unawaited ->
        %{result: result, killed: length(unawaited)}
      end)

  ## Handlers

  - `with_handler/1` - Production handler using Task.Supervisor
  - `with_sequential_handler/1` - Testing handler that runs synchronously

  ## BEAM Process Constraints

  Computations are spawned with a snapshot of `env` at fork time. Child
  changes to state don't propagate back. For shared mutable state across
  tasks, use `AtomicState` effect instead of regular `State`.
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Effects.Throw

  @sig __MODULE__

  #############################################################################
  ## Internal State Keys
  #############################################################################

  @supervisor_key {@sig, :supervisor}
  @boundaries_key {@sig, :boundaries}
  @current_boundary_key {@sig, :current_boundary}
  @sequential_results_key {@sig, :sequential_results}

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Async, [:comp])
  def_op(Await, [:handle])
  def_op(AwaitWithTimeout, [:handle, :timeout_ms])
  def_op(Cancel, [:handle])
  def_op(Boundary, [:comp, :on_unawaited])

  #############################################################################
  ## Handle Structure
  #############################################################################

  defmodule Handle do
    @moduledoc """
    Opaque handle for an async computation.

    Contains the boundary it belongs to and the underlying task (or ref for sequential).
    """
    @type t :: %__MODULE__{
            boundary_id: reference(),
            task_or_ref: Task.t() | reference()
          }
    defstruct [:boundary_id, :task_or_ref]
  end

  #############################################################################
  ## Public Operations
  #############################################################################

  @doc """
  Start a computation asynchronously, returning a handle.

  Must be called within an `Async.boundary/2` scope. The handle can only
  be awaited within the same boundary.

  ## Example

      Async.boundary(comp do
        handle <- Async.async(expensive_work())
        # ... do other work ...
        result <- Async.await(handle)
        result
      end)
  """
  @spec async(Types.computation()) :: Types.computation()
  def async(comp) do
    Comp.effect(@sig, %Async{comp: comp})
  end

  @doc """
  Wait for an async computation to complete and return its result.

  Uses a default timeout of 5 minutes. If the task does not complete within
  the timeout, it is cancelled and `{:error, :timeout}` is returned.

  For infinite wait, use `await_with_timeout(handle, :infinity)`.

  The handle must be from the current boundary. Awaiting a handle from
  a different boundary will throw an error.

  ## Example

      handle <- Async.async(work())
      result <- Async.await(handle)
  """
  @spec await(Handle.t()) :: Types.computation()
  def await(%Handle{} = handle) do
    Comp.effect(@sig, %Await{handle: handle})
  end

  @doc """
  Cancel an async task before awaiting it.

  The task is terminated and removed from the boundary's unawaited set.
  Returns `:ok`. Cancelling an already-completed or already-cancelled task
  is a no-op.

  ## Example

      Async.boundary(comp do
        h1 <- Async.async(approach_a())
        h2 <- Async.async(approach_b())

        # Use first result, cancel the other
        result <- Async.await(h1)
        _ <- Async.cancel(h2)
        result
      end)
  """
  @spec cancel(Handle.t()) :: Types.computation()
  def cancel(%Handle{} = handle) do
    Comp.effect(@sig, %Cancel{handle: handle})
  end

  @doc """
  Wait for an async computation with a timeout.

  Returns `{:ok, result}` if the task completes within the timeout,
  or `{:error, :timeout}` if it times out. On timeout, the task is
  automatically cancelled.

  The handle must be from the current boundary.

  ## Example

      handle <- Async.async(slow_work())
      case <- Async.await_with_timeout(handle, 5000)
      case do
        {:ok, result} -> result
        {:error, :timeout} -> :fallback
      end
  """
  @spec await_with_timeout(Handle.t(), non_neg_integer()) :: Types.computation()
  def await_with_timeout(%Handle{} = handle, timeout_ms) when is_integer(timeout_ms) do
    Comp.effect(@sig, %AwaitWithTimeout{handle: handle, timeout_ms: timeout_ms})
  end

  @doc """
  Run a computation with a timeout.

  This is a convenience function that wraps the computation in a boundary,
  runs it asynchronously, and awaits with a timeout. Returns `{:ok, result}`
  if the computation completes in time, or `{:error, :timeout}` if it times out.

  ## Example

      result <- Async.timeout(5000, expensive_work())
      case result do
        {:ok, value} -> value
        {:error, :timeout} -> :gave_up
      end

  This is equivalent to:

      Async.boundary(comp do
        h <- Async.async(expensive_work())
        Async.await_with_timeout(h, 5000)
      end)
  """
  @spec timeout(non_neg_integer(), Types.computation()) :: Types.computation()
  def timeout(timeout_ms, inner_comp) when is_integer(timeout_ms) do
    # Build the composed computation directly
    timeout_body =
      Comp.bind(
        async(inner_comp),
        fn handle ->
          await_with_timeout(handle, timeout_ms)
        end
      )

    # Wrap in a boundary that ignores unawaited (task is always awaited or timed out)
    boundary(timeout_body, fn result, _unawaited -> result end)
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
      Async.boundary(comp do
        h <- Async.async(work())
        # forgot await - will throw!
        :done
      end)

      # Custom: log warning, return result anyway
      Async.boundary(
        comp do
          h <- Async.async(fire_and_forget())
          :done
        end,
        fn result, unawaited ->
          Logger.warning("Killed \#{length(unawaited)} unawaited tasks")
          result
        end
      )

      # Custom: wrap result with metadata
      Async.boundary(my_comp, fn result, unawaited ->
        %{result: result, killed_tasks: length(unawaited)}
      end)
  """
  @spec boundary(Types.computation(), (term(), list(Handle.t()) -> term()) | nil) ::
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
  ## Production Handler (Task.Supervisor)
  #############################################################################

  @doc """
  Install a production Async handler using Task.Supervisor.

  Creates a Task.Supervisor that manages all async tasks. The supervisor
  is stopped when the handler scope exits.

  ## Example

      comp do
        Async.boundary(comp do
          h <- Async.async(work())
          Async.await(h)
        end)
      end
      |> Async.with_handler()
      |> Throw.with_handler()
      |> Comp.run!()
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(comp) do
    comp
    |> Comp.scoped(fn env ->
      {:ok, sup} = Task.Supervisor.start_link()

      modified =
        env
        |> Env.put_state(@supervisor_key, sup)
        |> Env.put_state(@boundaries_key, %{})
        |> Env.put_state(@current_boundary_key, nil)

      finally_k = fn value, e ->
        sup = Env.get_state(e, @supervisor_key)

        if sup && Process.alive?(sup) do
          try do
            Supervisor.stop(sup, :normal)
          catch
            :exit, _ -> :ok
          end
        end

        cleaned =
          %{
            e
            | state:
                e.state
                |> Map.delete(@supervisor_key)
                |> Map.delete(@boundaries_key)
                |> Map.delete(@current_boundary_key)
          }

        {value, cleaned}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &handle/3)
  end

  @impl Skuld.Comp.IHandler
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
          sup = Env.get_state(env_after, @supervisor_key)

          if sup do
            Enum.each(unawaited_handles, fn %Handle{task_or_ref: task} ->
              Task.Supervisor.terminate_child(sup, task.pid)
            end)
          end

          # Clean up boundary and restore previous
          env_cleaned =
            env_after
            |> Env.put_state(@boundaries_key, Map.delete(boundaries_after, boundary_id))
            |> Env.put_state(@current_boundary_key, prev_boundary)
            |> then(fn e ->
              %{e | state: Map.delete(e.state, {@sig, :boundary_previous, boundary_id})}
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
                  # on_unawaited can return a computation or a plain value
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

      # Create handle and track it (store full task struct)
      handle = %Handle{boundary_id: current_boundary, task_or_ref: task}

      boundaries = Env.get_state(env, @boundaries_key)
      boundary_tasks = Map.get(boundaries, current_boundary, MapSet.new())
      updated_tasks = MapSet.put(boundary_tasks, handle)

      env_tracked =
        Env.put_state(env, @boundaries_key, Map.put(boundaries, current_boundary, updated_tasks))

      k.(handle, env_tracked)
    end
  end

  # Default timeout for await/1 - 5 minutes
  @default_await_timeout_ms 5 * 60 * 1000

  def handle(
        %Await{handle: %Handle{boundary_id: handle_boundary, task_or_ref: task}},
        env,
        k
      ) do
    # await/1 returns the result directly (or {:error, reason} on failure/timeout)
    do_await_task(handle_boundary, task, @default_await_timeout_ms, :unwrap, env, k)
  end

  def handle(
        %AwaitWithTimeout{
          handle: %Handle{boundary_id: handle_boundary, task_or_ref: task},
          timeout_ms: timeout_ms
        },
        env,
        k
      ) do
    # await_with_timeout/2 returns {:ok, result} or {:error, reason}
    do_await_task(handle_boundary, task, timeout_ms, :wrap, env, k)
  end

  def handle(
        %Cancel{handle: %Handle{boundary_id: handle_boundary, task_or_ref: task} = handle},
        env,
        k
      ) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if handle_boundary != current_boundary do
      # Cross-boundary cancel - throw error via Throw effect
      Comp.call(Throw.throw({:error, :cancel_across_boundary}), env, k)
    else
      # Terminate the task
      sup = Env.get_state(env, @supervisor_key)

      if sup && Process.alive?(task.pid) do
        Task.Supervisor.terminate_child(sup, task.pid)
      end

      # Untrack the task
      boundaries = Env.get_state(env, @boundaries_key)
      boundary_tasks = Map.get(boundaries, current_boundary, MapSet.new())
      updated_tasks = MapSet.delete(boundary_tasks, handle)

      env_untracked =
        Env.put_state(env, @boundaries_key, Map.put(boundaries, current_boundary, updated_tasks))

      k.(:ok, env_untracked)
    end
  end

  defp do_await_task(handle_boundary, task, timeout_ms, wrap_mode, env, k) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if handle_boundary != current_boundary do
      # Cross-boundary await - throw error via Throw effect
      Comp.call(Throw.throw({:error, :await_across_boundary}), env, k)
    else
      # Wait for task result with timeout using Task.yield + Task.shutdown
      result =
        case Task.yield(task, timeout_ms) do
          {:ok, value} ->
            case wrap_mode do
              :unwrap -> value
              :wrap -> {:ok, value}
            end

          {:exit, reason} ->
            {:error, {:task_failed, reason}}

          nil ->
            # Timeout - shutdown the task
            Task.shutdown(task, :brutal_kill)
            {:error, :timeout}
        end

      # Untrack the task
      handle = %Handle{boundary_id: handle_boundary, task_or_ref: task}
      boundaries = Env.get_state(env, @boundaries_key)
      boundary_tasks = Map.get(boundaries, current_boundary, MapSet.new())
      updated_tasks = MapSet.delete(boundary_tasks, handle)

      env_untracked =
        Env.put_state(env, @boundaries_key, Map.put(boundaries, current_boundary, updated_tasks))

      k.(result, env_untracked)
    end
  end

  #############################################################################
  ## Sequential Handler (Testing)
  #############################################################################

  @doc """
  Install a sequential handler for testing.

  Runs async computations immediately and synchronously. Useful for testing
  logic without concurrency complexity.

  ## Example

      comp do
        Async.boundary(comp do
          h <- Async.async(work())
          Async.await(h)
        end)
      end
      |> Async.with_sequential_handler()
      |> Throw.with_handler()
      |> Comp.run!()
  """
  @spec with_sequential_handler(Types.computation()) :: Types.computation()
  def with_sequential_handler(comp) do
    comp
    |> Comp.scoped(fn env ->
      modified =
        env
        |> Env.put_state(@boundaries_key, %{})
        |> Env.put_state(@current_boundary_key, nil)
        |> Env.put_state(@sequential_results_key, %{})

      finally_k = fn value, e ->
        cleaned =
          %{
            e
            | state:
                e.state
                |> Map.delete(@boundaries_key)
                |> Map.delete(@current_boundary_key)
                |> Map.delete(@sequential_results_key)
          }

        {value, cleaned}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &handle_sequential/3)
  end

  defp handle_sequential(%Boundary{comp: inner_comp, on_unawaited: on_unawaited}, env, k) do
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

          # Clean up boundary and restore previous (no tasks to kill in sequential mode)
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

  defp handle_sequential(%Async{comp: comp}, env, k) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if current_boundary == nil do
      Comp.call(Throw.throw({:error, :async_outside_boundary}), env, k)
    else
      # Run computation immediately (sequential)
      {result, _final_env} = Comp.call(comp, env, fn v, e -> {v, e} end)

      # Create handle and store result
      handle_ref = make_ref()
      handle = %Handle{boundary_id: current_boundary, task_or_ref: handle_ref}

      results = Env.get_state(env, @sequential_results_key)

      env_with_result =
        Env.put_state(env, @sequential_results_key, Map.put(results, handle_ref, result))

      # Track handle
      boundaries = Env.get_state(env_with_result, @boundaries_key)
      boundary_tasks = Map.get(boundaries, current_boundary, MapSet.new())
      updated_tasks = MapSet.put(boundary_tasks, handle)

      env_tracked =
        Env.put_state(
          env_with_result,
          @boundaries_key,
          Map.put(boundaries, current_boundary, updated_tasks)
        )

      k.(handle, env_tracked)
    end
  end

  defp handle_sequential(
         %Await{handle: %Handle{boundary_id: handle_boundary, task_or_ref: handle_ref}},
         env,
         k
       ) do
    # await/1 returns the result directly
    do_await_sequential(handle_boundary, handle_ref, :unwrap, env, k)
  end

  defp handle_sequential(
         %AwaitWithTimeout{
           handle: %Handle{boundary_id: handle_boundary, task_or_ref: handle_ref},
           timeout_ms: _timeout_ms
         },
         env,
         k
       ) do
    # await_with_timeout/2 returns {:ok, result} (timeout doesn't apply in sequential mode)
    do_await_sequential(handle_boundary, handle_ref, :wrap, env, k)
  end

  defp handle_sequential(
         %Cancel{
           handle: %Handle{boundary_id: handle_boundary, task_or_ref: handle_ref} = handle
         },
         env,
         k
       ) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if handle_boundary != current_boundary do
      Comp.call(Throw.throw({:error, :cancel_across_boundary}), env, k)
    else
      # Remove stored result (no actual task to kill in sequential mode)
      results = Env.get_state(env, @sequential_results_key)

      env_without_result =
        Env.put_state(env, @sequential_results_key, Map.delete(results, handle_ref))

      # Untrack handle
      boundaries = Env.get_state(env_without_result, @boundaries_key)
      boundary_tasks = Map.get(boundaries, current_boundary, MapSet.new())
      updated_tasks = MapSet.delete(boundary_tasks, handle)

      env_untracked =
        Env.put_state(
          env_without_result,
          @boundaries_key,
          Map.put(boundaries, current_boundary, updated_tasks)
        )

      k.(:ok, env_untracked)
    end
  end

  defp do_await_sequential(handle_boundary, handle_ref, wrap_mode, env, k) do
    current_boundary = Env.get_state(env, @current_boundary_key)

    if handle_boundary != current_boundary do
      Comp.call(Throw.throw({:error, :await_across_boundary}), env, k)
    else
      # Get stored result (in sequential mode, computation already ran)
      results = Env.get_state(env, @sequential_results_key)
      result = Map.get(results, handle_ref)

      # Wrap or unwrap based on which operation was called
      final_result =
        case wrap_mode do
          :unwrap -> result
          :wrap -> {:ok, result}
        end

      # Untrack handle
      handle = %Handle{boundary_id: handle_boundary, task_or_ref: handle_ref}
      boundaries = Env.get_state(env, @boundaries_key)
      boundary_tasks = Map.get(boundaries, current_boundary, MapSet.new())
      updated_tasks = MapSet.delete(boundary_tasks, handle)

      env_untracked =
        Env.put_state(env, @boundaries_key, Map.put(boundaries, current_boundary, updated_tasks))

      k.(final_result, env_untracked)
    end
  end
end
