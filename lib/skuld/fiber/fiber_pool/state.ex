defmodule Skuld.Fiber.FiberPool.State do
  @moduledoc """
  State management for the FiberPool scheduler.

  Tracks fibers, their status, a FIFO run queue, and completion results.

  ## State Fields

  - `id` - Unique identifier for this pool instance
  - `fibers` - Map of fiber_id => Fiber.t() for all managed fibers
  - `run_queue` - FIFO queue of fiber_ids ready to run
  - `suspended` - Map of fiber_id => suspension_info for awaiting fibers
  - `completed` - Map of fiber_id => result for completed fibers
  - `awaiting` - Map of fiber_id => [awaiter_fiber_id] reverse index for wake-up
  - `tasks` - Map of task_ref => handle_id for running BEAM tasks
  - `task_supervisor` - Task.Supervisor pid for spawning tasks
  - `batch_suspended` - Map of fiber_id => BatchSuspend.t() for batch-waiting fibers
  - `opts` - Configuration options
  """

  alias Skuld.Fiber
  alias Skuld.Fiber.FiberPool.BatchSuspend

  @type fiber_id :: reference()
  @type task_ref :: reference()
  @type result :: {:ok, term()} | {:error, term()}

  @type suspension_info :: %{
          waiting_for: [fiber_id()],
          mode: :all | :any,
          collected: %{fiber_id() => result()}
        }

  @type t :: %__MODULE__{
          id: reference(),
          fibers: %{fiber_id() => Fiber.t()},
          run_queue: :queue.queue(fiber_id()),
          suspended: %{fiber_id() => suspension_info()},
          completed: %{fiber_id() => result()},
          awaiting: %{fiber_id() => [fiber_id()]},
          tasks: %{task_ref() => fiber_id()},
          task_supervisor: pid() | nil,
          batch_suspended: %{fiber_id() => BatchSuspend.t()},
          opts: keyword()
        }

  defstruct [
    :id,
    :fibers,
    :run_queue,
    :suspended,
    :completed,
    :awaiting,
    :tasks,
    :task_supervisor,
    :batch_suspended,
    :opts
  ]

  @doc """
  Create a new pool state.

  ## Options

  - `:on_error` - Error handling strategy (default: `:continue`)
    - `:continue` - Continue with other fibers on error
    - `:stop` - Stop scheduler on first error
  - `:task_supervisor` - Task.Supervisor pid for spawning tasks
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: make_ref(),
      fibers: %{},
      run_queue: :queue.new(),
      suspended: %{},
      completed: %{},
      awaiting: %{},
      tasks: %{},
      task_supervisor: Keyword.get(opts, :task_supervisor),
      batch_suspended: %{},
      opts: opts
    }
  end

  #############################################################################
  ## Fiber Management
  #############################################################################

  @doc """
  Add a fiber to the pool and enqueue it for running.

  Returns `{fiber_id, updated_state}`.
  """
  @spec add_fiber(t(), Fiber.t()) :: {fiber_id(), t()}
  def add_fiber(state, fiber) do
    fiber_id = fiber.id

    state =
      state
      |> put_in([Access.key(:fibers), fiber_id], fiber)
      |> update_in([Access.key(:run_queue)], &:queue.in(fiber_id, &1))

    {fiber_id, state}
  end

  @doc """
  Get a fiber by ID.
  """
  @spec get_fiber(t(), fiber_id()) :: Fiber.t() | nil
  def get_fiber(state, fiber_id) do
    Map.get(state.fibers, fiber_id)
  end

  @doc """
  Update a fiber in the pool.
  """
  @spec put_fiber(t(), Fiber.t()) :: t()
  def put_fiber(state, fiber) do
    put_in(state, [Access.key(:fibers), fiber.id], fiber)
  end

  @doc """
  Remove a fiber from the fibers map.
  """
  @spec remove_fiber(t(), fiber_id()) :: t()
  def remove_fiber(state, fiber_id) do
    %{state | fibers: Map.delete(state.fibers, fiber_id)}
  end

  #############################################################################
  ## Run Queue
  #############################################################################

  @doc """
  Enqueue a fiber_id to the run queue (FIFO - back of queue).
  """
  @spec enqueue(t(), fiber_id()) :: t()
  def enqueue(state, fiber_id) do
    update_in(state, [Access.key(:run_queue)], &:queue.in(fiber_id, &1))
  end

  @doc """
  Dequeue the next fiber_id from the run queue (FIFO - front of queue).

  Returns `{:ok, fiber_id, state}` or `{:empty, state}`.
  """
  @spec dequeue(t()) :: {:ok, fiber_id(), t()} | {:empty, t()}
  def dequeue(state) do
    case :queue.out(state.run_queue) do
      {{:value, fiber_id}, queue} ->
        {:ok, fiber_id, %{state | run_queue: queue}}

      {:empty, _queue} ->
        {:empty, state}
    end
  end

  @doc """
  Check if the run queue is empty.
  """
  @spec queue_empty?(t()) :: boolean()
  def queue_empty?(state) do
    :queue.is_empty(state.run_queue)
  end

  #############################################################################
  ## Completion Tracking
  #############################################################################

  @doc """
  Record a fiber's completion result.

  Also wakes up any fibers that were awaiting this fiber.
  Returns the updated state with any newly ready fibers enqueued.
  """
  @spec record_completion(t(), fiber_id(), result()) :: t()
  def record_completion(state, fiber_id, result) do
    state = put_in(state, [Access.key(:completed), fiber_id], result)

    # Wake up any fibers waiting for this one
    wake_awaiters(state, fiber_id, result)
  end

  @doc """
  Get a fiber's completion result.
  """
  @spec get_result(t(), fiber_id()) :: result() | nil
  def get_result(state, fiber_id) do
    Map.get(state.completed, fiber_id)
  end

  @doc """
  Check if a fiber has completed.
  """
  @spec completed?(t(), fiber_id()) :: boolean()
  def completed?(state, fiber_id) do
    Map.has_key?(state.completed, fiber_id)
  end

  #############################################################################
  ## Suspension / Await Tracking
  #############################################################################

  @doc """
  Suspend a fiber waiting for other fibers.

  - `fiber_id` - The fiber that is waiting
  - `waiting_for` - List of fiber_ids to wait for
  - `mode` - `:all` to wait for all, `:any` to wait for first

  Returns `{:suspended, state}` if the fiber must wait, or
  `{:ready, results, state}` if results are already available.
  """
  @spec suspend_awaiting(t(), fiber_id(), [fiber_id()], :all | :any) ::
          {:suspended, t()} | {:ready, term(), t()}
  def suspend_awaiting(state, fiber_id, waiting_for, mode) do
    # Check for already-completed fibers
    {already_done, still_waiting} =
      Enum.split_with(waiting_for, &completed?(state, &1))

    collected =
      Map.new(already_done, fn fid -> {fid, get_result(state, fid)} end)

    # Check if we can satisfy immediately
    case check_wake_condition(mode, waiting_for, collected) do
      {:ready, result} ->
        {:ready, result, state}

      :waiting ->
        # Need to suspend
        suspension = %{
          waiting_for: waiting_for,
          mode: mode,
          collected: collected
        }

        state = put_in(state, [Access.key(:suspended), fiber_id], suspension)

        # Add reverse index: for each fiber we're waiting on, record that we're awaiting it
        state =
          Enum.reduce(still_waiting, state, fn target_fid, acc ->
            update_in(acc, [Access.key(:awaiting), target_fid], fn
              nil -> [fiber_id]
              list -> [fiber_id | list]
            end)
          end)

        {:suspended, state}
    end
  end

  @doc """
  Remove a suspension (after fiber is woken or cancelled).
  """
  @spec remove_suspension(t(), fiber_id()) :: t()
  def remove_suspension(state, fiber_id) do
    case Map.get(state.suspended, fiber_id) do
      nil ->
        state

      %{waiting_for: waiting_for} ->
        # Remove from awaiting reverse index
        state =
          Enum.reduce(waiting_for, state, fn target_fid, acc ->
            update_in(acc, [Access.key(:awaiting), target_fid], fn
              nil -> nil
              list -> List.delete(list, fiber_id)
            end)
          end)

        %{state | suspended: Map.delete(state.suspended, fiber_id)}
    end
  end

  #############################################################################
  ## Wake Logic
  #############################################################################

  # Wake up fibers that were awaiting a completed fiber
  defp wake_awaiters(state, completed_fid, result) do
    awaiters = Map.get(state.awaiting, completed_fid, [])

    # Remove from awaiting index
    state = %{state | awaiting: Map.delete(state.awaiting, completed_fid)}

    # Process each awaiter
    Enum.reduce(awaiters, state, fn awaiter_fid, acc ->
      wake_if_ready(acc, awaiter_fid, completed_fid, result)
    end)
  end

  # Check if an awaiter is ready to wake
  defp wake_if_ready(state, awaiter_fid, completed_fid, result) do
    case Map.get(state.suspended, awaiter_fid) do
      nil ->
        # Already woken or cancelled
        state

      suspension ->
        # Add to collected
        collected = Map.put(suspension.collected, completed_fid, result)

        case check_wake_condition(suspension.mode, suspension.waiting_for, collected) do
          {:ready, wake_result} ->
            # Wake the fiber
            state = remove_suspension(state, awaiter_fid)

            # Store wake result for the fiber to retrieve
            # We use a special key in completed to signal "ready to resume with this value"
            state = put_in(state, [Access.key(:completed), {:wake, awaiter_fid}], wake_result)

            # Enqueue the fiber
            enqueue(state, awaiter_fid)

          :waiting ->
            # Update collected but still waiting
            updated = %{suspension | collected: collected}
            put_in(state, [Access.key(:suspended), awaiter_fid], updated)
        end
    end
  end

  # Check if wake condition is satisfied
  defp check_wake_condition(:any, _waiting_for, collected) when map_size(collected) > 0 do
    [{fid, result}] = Enum.take(collected, 1)
    {:ready, {fid, result}}
  end

  defp check_wake_condition(:any, _waiting_for, _collected) do
    :waiting
  end

  defp check_wake_condition(:all, waiting_for, collected) do
    if Enum.all?(waiting_for, &Map.has_key?(collected, &1)) do
      # Return results in order
      results = Enum.map(waiting_for, &Map.fetch!(collected, &1))
      {:ready, results}
    else
      :waiting
    end
  end

  @doc """
  Get and clear the wake result for a fiber.
  """
  @spec pop_wake_result(t(), fiber_id()) :: {term() | nil, t()}
  def pop_wake_result(state, fiber_id) do
    key = {:wake, fiber_id}

    case Map.pop(state.completed, key) do
      {nil, _} -> {nil, state}
      {result, completed} -> {result, %{state | completed: completed}}
    end
  end

  #############################################################################
  ## Task Management
  #############################################################################

  @doc """
  Register a running task with its handle_id.

  The task_ref is the reference from Task.async, used to match completion messages.
  The handle_id is the fiber_id used in the Handle returned to the user.
  """
  @spec add_task(t(), task_ref(), fiber_id()) :: t()
  def add_task(state, task_ref, handle_id) do
    %{state | tasks: Map.put(state.tasks, task_ref, handle_id)}
  end

  @doc """
  Get the handle_id for a task_ref.
  """
  @spec get_task_handle(t(), task_ref()) :: fiber_id() | nil
  def get_task_handle(state, task_ref) do
    Map.get(state.tasks, task_ref)
  end

  @doc """
  Remove a task and return its handle_id.
  """
  @spec pop_task(t(), task_ref()) :: {fiber_id() | nil, t()}
  def pop_task(state, task_ref) do
    case Map.pop(state.tasks, task_ref) do
      {nil, _} -> {nil, state}
      {handle_id, tasks} -> {handle_id, %{state | tasks: tasks}}
    end
  end

  @doc """
  Check if there are any running tasks.
  """
  @spec has_tasks?(t()) :: boolean()
  def has_tasks?(state) do
    map_size(state.tasks) > 0
  end

  #############################################################################
  ## Batch Suspension Management
  #############################################################################

  @doc """
  Record a fiber as suspended waiting for batch execution.

  The fiber will be resumed when batch results are available.
  """
  @spec add_batch_suspension(t(), fiber_id(), BatchSuspend.t()) :: t()
  def add_batch_suspension(state, fiber_id, batch_suspend) do
    %{state | batch_suspended: Map.put(state.batch_suspended, fiber_id, batch_suspend)}
  end

  @doc """
  Get all batch-suspended fibers as a list of {fiber_id, BatchSuspend.t()}.
  """
  @spec get_batch_suspensions(t()) :: [{fiber_id(), BatchSuspend.t()}]
  def get_batch_suspensions(state) do
    Map.to_list(state.batch_suspended)
  end

  @doc """
  Remove a batch suspension (after fiber is resumed).
  """
  @spec remove_batch_suspension(t(), fiber_id()) :: t()
  def remove_batch_suspension(state, fiber_id) do
    %{state | batch_suspended: Map.delete(state.batch_suspended, fiber_id)}
  end

  @doc """
  Clear all batch suspensions and return them.

  Used when executing a batch - all suspended fibers are removed and will be
  resumed with their results.
  """
  @spec pop_all_batch_suspensions(t()) :: {[{fiber_id(), BatchSuspend.t()}], t()}
  def pop_all_batch_suspensions(state) do
    suspensions = Map.to_list(state.batch_suspended)
    {suspensions, %{state | batch_suspended: %{}}}
  end

  @doc """
  Check if there are any batch-suspended fibers.
  """
  @spec has_batch_suspensions?(t()) :: boolean()
  def has_batch_suspensions?(state) do
    map_size(state.batch_suspended) > 0
  end

  #############################################################################
  ## Status Checks
  #############################################################################

  @doc """
  Check if any work is pending (fibers in queue, suspended, batch-suspended, or tasks running).
  """
  @spec active?(t()) :: boolean()
  def active?(state) do
    not :queue.is_empty(state.run_queue) or
      map_size(state.suspended) > 0 or
      map_size(state.fibers) > 0 or
      map_size(state.tasks) > 0 or
      map_size(state.batch_suspended) > 0
  end

  @doc """
  Check if all submitted fibers and tasks have completed.
  """
  @spec all_done?(t()) :: boolean()
  def all_done?(state) do
    :queue.is_empty(state.run_queue) and
      map_size(state.suspended) == 0 and
      map_size(state.fibers) == 0 and
      map_size(state.tasks) == 0 and
      map_size(state.batch_suspended) == 0
  end

  @doc """
  Get counts for debugging/metrics.
  """
  @spec counts(t()) :: map()
  def counts(state) do
    %{
      fibers: map_size(state.fibers),
      run_queue: :queue.len(state.run_queue),
      suspended: map_size(state.suspended),
      completed: map_size(state.completed),
      tasks: map_size(state.tasks),
      batch_suspended: map_size(state.batch_suspended)
    }
  end
end
