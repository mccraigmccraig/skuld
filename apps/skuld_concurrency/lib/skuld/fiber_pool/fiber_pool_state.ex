# State management for the FiberPool scheduler.
#
# Tracks fibers, their status, a FIFO run queue, and completion results.
#
# ## State Fields
#
# - `id` - Unique identifier for this pool instance
# - `fibers` - Map of fiber_id => Coroutine.t() for all managed fibers
# - `run_queue` - FIFO queue of fiber_ids ready to run
# - `suspensions` - Map of fiber_id => Suspension.t() for all suspended fibers
# - `completed` - Map of fiber_id => result for completed fibers
# - `wake_signals` - Map of awaiter_id => resume_value for fibers ready to wake
# - `consume_ids` - Map of fiber_id => [fiber_id] for deferred result cleanup
# - `awaiting` - Map of fiber_id => [awaiter_fiber_id] reverse index for wake-up
# - `foreign_suspends` - Map of fiber_id => Coroutine.t() for fibers suspended on foreign resources
# - `tasks` - Map of task_ref => handle_id for running BEAM tasks
# - `task_supervisor` - Task.Supervisor pid for spawning tasks
# - `opts` - Configuration options
defmodule Skuld.FiberPool.FiberPoolState do
  @moduledoc false

  alias Skuld.Coroutine
  alias Skuld.Comp.InternalSuspend

  @type fiber_id :: term()
  # awaiter_id can be a fiber reference or :main for the main computation
  @type awaiter_id :: fiber_id() | :main
  @type task_ref :: reference()
  @type result :: {:ok, term()} | {:error, term()}

  defmodule Suspension do
    @moduledoc false

    defmodule Await do
      @moduledoc false

      @type t :: %__MODULE__{
              waiting_for: [reference()],
              mode: :all | :any,
              collected: %{reference() => term()}
            }

      defstruct [:waiting_for, :mode, :collected]
    end

    defmodule Batch do
      @moduledoc false

      @type t :: %__MODULE__{
              internal_suspend: InternalSuspend.t()
            }

      defstruct [:internal_suspend]
    end

    defmodule Channel do
      @moduledoc false

      @type t :: %__MODULE__{}

      defstruct []
    end

    defmodule FiberYield do
      @moduledoc false

      @type t :: %__MODULE__{value: term(), notify: boolean()}

      defstruct [:value, notify: false]
    end

    @type t :: Await.t() | Batch.t() | Channel.t() | FiberYield.t()
  end

  @type t :: %__MODULE__{
          id: term(),
          fibers: %{fiber_id() => Coroutine.t()},
          run_queue: :queue.queue(fiber_id()),
          suspensions: %{awaiter_id() => Suspension.t()},
          completed: %{fiber_id() => result()},
          wake_signals: %{awaiter_id() => term()},
          consume_ids: %{fiber_id() => [fiber_id()]},
          awaiting: %{fiber_id() => [fiber_id()]},
          foreign_suspends: %{fiber_id() => Coroutine.t()},
          tasks: %{task_ref() => fiber_id()},
          task_supervisor: pid() | nil,
          env_state: %{term() => term()},
          opts: keyword()
        }

  defstruct [
    :id,
    :fibers,
    :run_queue,
    :suspensions,
    :completed,
    :wake_signals,
    :consume_ids,
    :awaiting,
    :foreign_suspends,
    :tasks,
    :task_supervisor,
    :env_state,
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
      id: Keyword.get(opts, :id),
      fibers: %{},
      run_queue: :queue.new(),
      suspensions: %{},
      completed: %{},
      wake_signals: %{},
      consume_ids: %{},
      awaiting: %{},
      foreign_suspends: %{},
      tasks: %{},
      task_supervisor: Keyword.get(opts, :task_supervisor),
      env_state: Keyword.get(opts, :env_state, %{}),
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
  @spec add_fiber(t(), Coroutine.t()) :: {fiber_id(), t()}
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
  @spec get_fiber(t(), fiber_id()) :: Coroutine.t() | nil
  def get_fiber(state, fiber_id) do
    Map.get(state.fibers, fiber_id)
  end

  @doc """
  Update a fiber in the pool.
  """
  @spec put_fiber(t(), Coroutine.t()) :: t()
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
  @spec suspend_awaiting(t(), awaiter_id(), [fiber_id()], :all | :any) ::
          {:suspended, t()} | {:ready, term(), t()}
  def suspend_awaiting(state, awaiter_id, waiting_for, mode) do
    # Check for already-completed fibers
    {already_done, still_waiting} =
      Enum.split_with(waiting_for, &completed?(state, &1))

    collected =
      Map.new(already_done, fn fid -> {fid, get_result(state, fid)} end)

    # Check if we can satisfy immediately
    case check_wake_condition(mode, waiting_for, collected) do
      {:ready, result} ->
        # Note: we don't clean up here because the fiber might be awaited again
        # (e.g., by scope's await_all). Cleanup happens in wake_awaiters when
        # a fiber completes with registered awaiters.
        {:ready, result, state}

      :waiting ->
        # Need to suspend
        state =
          put_in(state, [Access.key(:suspensions), awaiter_id], %Suspension.Await{
            waiting_for: waiting_for,
            mode: mode,
            collected: collected
          })

        # Add reverse index: for each fiber we're waiting on, record that we're awaiting it
        state =
          Enum.reduce(still_waiting, state, fn target_fid, acc ->
            update_in(acc, [Access.key(:awaiting), target_fid], fn
              nil -> [awaiter_id]
              list -> [awaiter_id | list]
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
    case Map.get(state.suspensions, fiber_id) do
      nil ->
        state

      %Suspension.Await{waiting_for: waiting_for} ->
        # Remove from awaiting reverse index
        state =
          Enum.reduce(waiting_for, state, fn target_fid, acc ->
            update_in(acc, [Access.key(:awaiting), target_fid], fn
              nil -> nil
              list -> List.delete(list, fiber_id)
            end)
          end)

        %{state | suspensions: Map.delete(state.suspensions, fiber_id)}

      _ ->
        %{state | suspensions: Map.delete(state.suspensions, fiber_id)}
    end
  end

  @doc """
  Record a fiber suspension (generic — no type-specific logic).
  """
  @spec put_suspension(t(), fiber_id(), Suspension.t()) :: t()
  def put_suspension(state, fiber_id, suspension) do
    %{state | suspensions: Map.put(state.suspensions, fiber_id, suspension)}
  end

  @doc """
  Check if a fiber has a suspension entry.
  """
  @spec suspended?(t(), fiber_id()) :: boolean()
  def suspended?(state, fiber_id) do
    Map.has_key?(state.suspensions, fiber_id)
  end

  @doc """
  Remove a suspension generically, with Await cleanup.
  """
  @spec delete_suspension(t(), fiber_id()) :: t()
  def delete_suspension(state, fiber_id) do
    case Map.get(state.suspensions, fiber_id) do
      %Suspension.Await{waiting_for: waiting_for} ->
        state =
          Enum.reduce(waiting_for, state, fn target_fid, acc ->
            update_in(acc, [Access.key(:awaiting), target_fid], fn
              nil -> nil
              list -> List.delete(list, fiber_id)
            end)
          end)

        %{state | suspensions: Map.delete(state.suspensions, fiber_id)}

      _ ->
        %{state | suspensions: Map.delete(state.suspensions, fiber_id)}
    end
  end

  #############################################################################
  ## Wake Logic
  #############################################################################

  # Wake up fibers that were awaiting a completed fiber
  defp wake_awaiters(state, completed_fid, result) do
    awaiting = state.awaiting || %{}
    awaiters = Map.get(awaiting, completed_fid, []) || []

    # Remove from awaiting index
    state = %{state | awaiting: Map.delete(awaiting, completed_fid)}

    # Process each awaiter
    Enum.reduce(awaiters, state, fn awaiter_fid, acc ->
      wake_if_ready(acc, awaiter_fid, completed_fid, result)
    end)

    # Note: We don't clean up completed[completed_fid] here because the fiber
    # might be awaited again later (e.g., by scope's await_all). The completed
    # map is cleaned up when the FiberPool run ends.
  end

  # Check if an awaiter is ready to wake
  defp wake_if_ready(state, awaiter_fid, completed_fid, result) do
    case Map.get(state.suspensions, awaiter_fid) do
      nil ->
        # Already woken or cancelled
        state

      %Suspension.Await{waiting_for: waiting_for, mode: mode, collected: collected} ->
        collected = Map.put(collected, completed_fid, result)

        case check_wake_condition(mode, waiting_for, collected) do
          {:ready, wake_result} ->
            state = remove_suspension(state, awaiter_fid)
            state = put_in(state, [Access.key(:wake_signals), awaiter_fid], wake_result)
            enqueue(state, awaiter_fid)

          :waiting ->
            updated = %Suspension.Await{
              waiting_for: waiting_for,
              mode: mode,
              collected: collected
            }

            put_in(state, [Access.key(:suspensions), awaiter_fid], updated)
        end

      _ ->
        state
    end
  end

  # Check if wake condition is satisfied
  defp check_wake_condition(:one, [fid], collected) do
    # For :one mode, we're waiting for a single fiber
    case Map.get(collected, fid) do
      nil -> :waiting
      result -> {:ready, result}
    end
  end

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
  @spec pop_wake_result(t(), awaiter_id()) :: {term() | nil, t()}
  def pop_wake_result(state, awaiter_id) do
    case Map.pop(state.wake_signals, awaiter_id) do
      {nil, _} -> {nil, state}
      {result, wake_signals} -> {result, %{state | wake_signals: wake_signals}}
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
  """
  @spec add_batch_suspension(t(), fiber_id(), InternalSuspend.t()) :: t()
  def add_batch_suspension(state, fiber_id, batch_suspend) do
    %{
      state
      | suspensions:
          Map.put(state.suspensions, fiber_id, %Suspension.Batch{internal_suspend: batch_suspend})
    }
  end

  @doc """
  Get all batch-suspended fibers as a list of {fiber_id, InternalSuspend.t()}.
  """
  @spec get_batch_suspensions(t()) :: [{fiber_id(), InternalSuspend.t()}]
  def get_batch_suspensions(state) do
    for {fid, %Suspension.Batch{internal_suspend: s}} <- state.suspensions, do: {fid, s}
  end

  @doc """
  Clear all batch suspensions and return them.
  """
  @spec pop_all_batch_suspensions(t()) :: {[{fiber_id(), InternalSuspend.t()}], t()}
  def pop_all_batch_suspensions(state) do
    {batch, rest} =
      state.suspensions
      |> Enum.split_with(fn {_, s} -> match?(%Suspension.Batch{}, s) end)

    suspensions = for {fid, %Suspension.Batch{internal_suspend: s}} <- batch, do: {fid, s}
    remaining = Map.new(rest)
    {suspensions, %{state | suspensions: remaining}}
  end

  @doc """
  Check if there are any batch-suspended fibers.
  """
  @spec has_batch_suspensions?(t()) :: boolean()
  def has_batch_suspensions?(state) do
    Enum.any?(state.suspensions, fn {_, s} -> match?(%Suspension.Batch{}, s) end)
  end

  @doc """
  Remove a batch suspension (after fiber is resumed).
  """
  @spec remove_batch_suspension(t(), fiber_id()) :: t()
  def remove_batch_suspension(state, fiber_id) do
    %{state | suspensions: Map.delete(state.suspensions, fiber_id)}
  end

  #############################################################################
  ## Status Checks
  #############################################################################

  @doc """
  Check if any work is pending (fibers in queue, suspended, batch-suspended, channel-suspended, or tasks running).
  """
  @spec active?(t()) :: boolean()
  def active?(state) do
    not :queue.is_empty(state.run_queue) or
      map_size(state.suspensions) > 0 or
      map_size(state.fibers) > 0 or
      map_size(state.tasks) > 0
  end

  @doc """
  Check if all submitted fibers and tasks have completed.
  """
  @spec all_done?(t()) :: boolean()
  def all_done?(state) do
    :queue.is_empty(state.run_queue) and
      map_size(state.suspensions) == 0 and
      map_size(state.fibers) == 0 and
      map_size(state.tasks) == 0
  end

  @doc """
  Get counts for debugging/metrics.
  """
  @spec counts(t()) :: map()
  def counts(state) do
    %{
      fibers: map_size(state.fibers),
      run_queue: :queue.len(state.run_queue),
      suspensions: map_size(state.suspensions),
      completed: map_size(state.completed),
      tasks: map_size(state.tasks)
    }
  end

  #############################################################################
  ## Progress Detection (Deadlock Detection Support)
  #############################################################################

  defmodule ProgressSnapshot do
    @moduledoc false

    @type t :: %__MODULE__{
            fibers: non_neg_integer(),
            run_queue: non_neg_integer(),
            suspensions: non_neg_integer(),
            completed: non_neg_integer(),
            wake_signals: non_neg_integer(),
            tasks: non_neg_integer()
          }

    defstruct [
      :fibers,
      :run_queue,
      :suspensions,
      :completed,
      :wake_signals,
      :tasks
    ]
  end

  @typedoc """
  Snapshot of pool state sizes for deadlock detection.

  Captures the sizes of all mutable collections so that `progressed?/2`
  can cheaply determine whether a `Scheduler.step` made forward progress.
  """
  @type progress_snapshot :: ProgressSnapshot.t()

  @doc """
  Take a lightweight snapshot of the scheduler state for progress detection.

  Used before a `Scheduler.step` call — compare with a snapshot taken after
  the step via `progressed?/2` to detect whether the step made meaningful
  forward progress.
  """
  @spec progress_snapshot(t()) :: progress_snapshot()
  def progress_snapshot(state) do
    %ProgressSnapshot{
      fibers: map_size(state.fibers),
      run_queue: :queue.len(state.run_queue),
      suspensions: map_size(state.suspensions),
      completed: map_size(state.completed),
      wake_signals: map_size(state.wake_signals),
      tasks: map_size(state.tasks)
    }
  end

  @doc """
  Determine whether the scheduler state evolved meaningfully between two snapshots.

  Returns `true` if any of the tracked collection sizes changed, indicating
  that a fiber completed, a suspension was added or resolved, a task finished,
  etc. Returns `false` if the state is structurally identical — suggesting the
  scheduler is stuck and no forward progress is being made.
  """
  @spec progressed?(progress_snapshot(), progress_snapshot()) :: boolean()
  def progressed?(before, after_) do
    before != after_
  end

  #############################################################################
  ## Shared Env State Management
  #############################################################################

  @doc """
  Get the shared env.state map.

  This state is threaded through all fibers in the pool, allowing
  effects like Channel, Writer, and State to compound across fibers.
  """
  @spec get_env_state(t()) :: %{term() => term()}
  def get_env_state(state) do
    state.env_state
  end

  @doc """
  Update the shared env.state map.

  Called after each fiber completes or suspends to capture its state updates.
  """
  @spec put_env_state(t(), %{term() => term()}) :: t()
  def put_env_state(state, env_state) when is_map(env_state) do
    %{state | env_state: env_state}
  end

  def put_env_state(state, nil) do
    # Guard against nil - keep existing env_state
    state
  end
end
