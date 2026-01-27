defmodule Skuld.Effects.Async.Scheduler.State do
  @moduledoc """
  State management for the cooperative scheduler.

  Tracks suspended computations, their await requests, collected completions,
  and a FIFO run queue of computations ready to resume.

  ## State Fields

  - `suspended` - Map of request_id => suspension_info for waiting computations
  - `waiting_for` - Reverse index: target_key => request_id for fast completion lookup
  - `run_queue` - FIFO queue of `{request_id, results}` ready to resume
  - `completed` - Map of request_id => final_result for completed computations
  - `opts` - Configuration options

  ## Suspension Info

  Each suspended computation tracks:
  - `resume` - Function to call with results
  - `request` - The AwaitRequest being waited on
  - `collected` - Results collected so far (for :all mode)
  - `suspended_at` - Monotonic timestamp for debugging/metrics
  """

  alias Skuld.Effects.Async.AwaitRequest
  alias AwaitRequest.Target

  defstruct [
    :suspended,
    :waiting_for,
    :run_queue,
    :completed,
    :early_completions,
    # Fiber support
    :fibers,
    :fiber_results,
    :fibers_to_cancel,
    :opts
  ]

  @type target_key :: AwaitRequest.target_key()
  @type result :: {:ok, term()} | {:error, term()}

  @type suspension_info :: %{
          resume: (term() -> term()),
          request: AwaitRequest.t(),
          collected: %{target_key() => result()},
          suspended_at: integer()
        }

  @type ready_item :: {reference(), (term() -> term()), term()} | {:fiber, reference()}

  @type fiber_info :: %{
          comp: Skuld.Comp.Types.computation(),
          boundary_id: reference(),
          env: Skuld.Comp.Env.t()
        }

  @type t :: %__MODULE__{
          suspended: %{reference() => suspension_info()},
          waiting_for: %{target_key() => reference()},
          run_queue: :queue.queue(ready_item()),
          completed: %{reference() => term()},
          early_completions: %{target_key() => result()},
          # Fiber support
          fibers: %{reference() => fiber_info()},
          fiber_results: %{reference() => result()},
          fibers_to_cancel: %{reference() => true},
          opts: keyword()
        }

  @doc """
  Create a new scheduler state.

  ## Options

  - `:on_error` - Error handling strategy (default: `:log_and_continue`)
    - `:log_and_continue` - Log error and continue with other computations
    - `:stop` - Stop scheduler on first error
    - `{:callback, fun}` - Call `fun.(error, state)` to handle
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      suspended: %{},
      waiting_for: %{},
      run_queue: :queue.new(),
      completed: %{},
      early_completions: %{},
      fibers: %{},
      fiber_results: %{},
      fibers_to_cancel: %{},
      opts: opts
    }
  end

  @doc """
  Add a suspended computation to track.

  Creates the waiting_for reverse index entries for fast completion lookup.
  Also checks for early completions that arrived before we started waiting.

  Returns `{:suspended, state}` if waiting, or `{:ready, state}` if early
  completions immediately satisfied the wake condition.
  """
  @spec add_suspension(t(), reference(), AwaitRequest.t(), (term() -> term())) ::
          {:suspended, t()} | {:ready, t()}
  def add_suspension(state, request_id, request, resume) do
    target_keys = Enum.map(request.targets, &Target.key/1)

    # Check for early completions
    {collected, remaining_early} =
      Enum.reduce(target_keys, {%{}, state.early_completions}, fn key, {coll, early} ->
        case Map.pop(early, key) do
          {nil, early} -> {coll, early}
          {result, early} -> {Map.put(coll, key, result), early}
        end
      end)

    state = %{state | early_completions: remaining_early}

    # Check if early completions satisfy wake condition
    case check_wake(request, collected) do
      {:ready, wake_result} ->
        # Already have all results - enqueue directly
        state = enqueue_ready(state, request_id, resume, wake_result)
        {:ready, state}

      :waiting ->
        # Need to wait for more completions
        suspension_info = %{
          resume: resume,
          request: request,
          collected: collected,
          suspended_at: System.monotonic_time(:millisecond)
        }

        # Build reverse index: target_key => request_id
        # Only for targets we don't already have completions for
        waiting_for =
          Enum.reduce(target_keys, state.waiting_for, fn key, acc ->
            if Map.has_key?(collected, key) do
              acc
            else
              Map.put(acc, key, request_id)
            end
          end)

        {:suspended,
         %{
           state
           | suspended: Map.put(state.suspended, request_id, suspension_info),
             waiting_for: waiting_for
         }}
    end
  end

  @doc """
  Remove a suspension (after completion or cancellation).

  Cleans up the waiting_for reverse index entries.
  """
  @spec remove_suspension(t(), reference()) :: t()
  def remove_suspension(state, request_id) do
    case Map.get(state.suspended, request_id) do
      nil ->
        state

      %{request: request} ->
        # Remove waiting_for entries
        target_keys = Enum.map(request.targets, &Target.key/1)

        waiting_for =
          Enum.reduce(target_keys, state.waiting_for, fn key, acc ->
            Map.delete(acc, key)
          end)

        %{state | suspended: Map.delete(state.suspended, request_id), waiting_for: waiting_for}
    end
  end

  @doc """
  Record a completion for a target.

  Returns `{:woke, request_id, wake_result, state}` if this completion
  caused a computation to become ready, or `{:waiting, state}` otherwise.

  If no one is waiting for this target, stores it as an early completion
  for later retrieval when a suspension is added.
  """
  @spec record_completion(t(), target_key(), result()) ::
          {:woke, reference(), term(), t()} | {:waiting, t()}
  def record_completion(state, target_key, result) do
    case Map.get(state.waiting_for, target_key) do
      nil ->
        # No one waiting for this target yet - store as early completion
        # This happens when a task completes before we await it
        # Don't overwrite existing early completion (e.g., task result arrives
        # before DOWN message - keep the result, ignore the DOWN)
        if Map.has_key?(state.early_completions, target_key) do
          {:waiting, state}
        else
          early = Map.put(state.early_completions, target_key, result)
          {:waiting, %{state | early_completions: early}}
        end

      request_id ->
        case Map.get(state.suspended, request_id) do
          nil ->
            # Suspension was already removed - store as early completion
            early = Map.put(state.early_completions, target_key, result)
            {:waiting, %{state | early_completions: early}}

          suspension_info ->
            # Add to collected results
            collected = Map.put(suspension_info.collected, target_key, result)
            updated_info = %{suspension_info | collected: collected}

            # Check wake condition
            case check_wake(updated_info.request, collected) do
              {:ready, wake_result} ->
                # Remove from suspended, add to run queue
                state = remove_suspension(state, request_id)
                state = enqueue_ready(state, request_id, updated_info.resume, wake_result)
                {:woke, request_id, wake_result, state}

              :waiting ->
                # Update collected but still waiting
                suspended = Map.put(state.suspended, request_id, updated_info)
                {:waiting, %{state | suspended: suspended}}
            end
        end
    end
  end

  @doc """
  Check if a request's wake conditions are met.

  - `:any` mode - Ready when any target has completed
  - `:all` mode - Ready when all targets have completed
  """
  @spec check_wake(AwaitRequest.t(), %{target_key() => result()}) :: {:ready, term()} | :waiting
  def check_wake(%AwaitRequest{mode: :any}, collected) when map_size(collected) > 0 do
    # Return first completion as {target_key, result}
    [{target_key, result}] = Enum.take(collected, 1)
    {:ready, {target_key, result}}
  end

  def check_wake(%AwaitRequest{mode: :any}, _collected) do
    :waiting
  end

  def check_wake(%AwaitRequest{mode: :all, targets: targets}, collected) do
    target_keys = Enum.map(targets, &Target.key/1)

    if Enum.all?(target_keys, &Map.has_key?(collected, &1)) do
      # All complete - return results in target order
      results = Enum.map(target_keys, &Map.fetch!(collected, &1))
      {:ready, results}
    else
      :waiting
    end
  end

  @doc """
  Add a ready computation to the run queue (FIFO - back of queue).
  """
  @spec enqueue_ready(t(), reference(), (term() -> term()), term()) :: t()
  def enqueue_ready(state, request_id, resume, results) do
    item = {request_id, resume, results}
    %{state | run_queue: :queue.in(item, state.run_queue)}
  end

  @doc """
  Dequeue the next ready computation (FIFO - front of queue).

  Returns `{:ok, item, state}` or `{:empty, state}`.

  Items can be:
  - `{request_id, resume, results}` - a computation ready to resume
  - `{:fiber, fiber_id}` - a fiber ready to run
  """
  @spec dequeue_one(t()) ::
          {:ok, {reference(), (term() -> term()), term()}, t()}
          | {:ok, {:fiber, reference()}, t()}
          | {:empty, t()}
  def dequeue_one(state) do
    case :queue.out(state.run_queue) do
      {{:value, item}, queue} ->
        {:ok, item, %{state | run_queue: queue}}

      {:empty, _queue} ->
        {:empty, state}
    end
  end

  @doc """
  Record a computation's final result.

  The tag can be any term - typically a reference, but can also be atoms
  like `:main` or tuples like `{:index, idx}` for tracking purposes.
  """
  @spec record_completed(t(), term(), term()) :: t()
  def record_completed(state, request_id, result) do
    %{state | completed: Map.put(state.completed, request_id, result)}
  end

  @doc """
  Check if any computations are still active (suspended, in run queue, or fibers running).
  """
  @spec active?(t()) :: boolean()
  def active?(state) do
    map_size(state.suspended) > 0 or
      not :queue.is_empty(state.run_queue) or
      map_size(state.fibers) > 0
  end

  @doc """
  Get counts for debugging/metrics.
  """
  @spec counts(t()) :: %{
          suspended: non_neg_integer(),
          ready: non_neg_integer(),
          completed: non_neg_integer(),
          fibers: non_neg_integer(),
          fiber_results: non_neg_integer(),
          fibers_to_cancel: non_neg_integer()
        }
  def counts(state) do
    %{
      suspended: map_size(state.suspended),
      ready: :queue.len(state.run_queue),
      completed: map_size(state.completed),
      fibers: map_size(state.fibers),
      fiber_results: map_size(state.fiber_results),
      fibers_to_cancel: map_size(state.fibers_to_cancel)
    }
  end

  @doc """
  Mark fiber IDs for cancellation.

  When the scheduler tries to run these fibers, it will cancel them instead.
  """
  @spec mark_fibers_to_cancel(t(), [reference()]) :: t()
  def mark_fibers_to_cancel(state, fiber_ids) do
    new_cancellations = Map.new(fiber_ids, fn id -> {id, true} end)
    %{state | fibers_to_cancel: Map.merge(state.fibers_to_cancel, new_cancellations)}
  end

  @doc """
  Check if a fiber is marked for cancellation.
  """
  @spec fiber_cancelled?(t(), reference()) :: boolean()
  def fiber_cancelled?(state, fiber_id) do
    Map.has_key?(state.fibers_to_cancel, fiber_id)
  end

  @doc """
  Remove a fiber from the cancellation set (after it's been cancelled).
  """
  @spec clear_cancelled_fiber(t(), reference()) :: t()
  def clear_cancelled_fiber(state, fiber_id) do
    %{state | fibers_to_cancel: Map.delete(state.fibers_to_cancel, fiber_id)}
  end

  #############################################################################
  ## Fiber Management
  #############################################################################

  @doc """
  Add a fiber to the scheduler.

  The fiber is stored in the fibers map and added to the run queue.
  The env is captured so the fiber can inherit the parent's environment.
  """
  @spec add_fiber(
          t(),
          reference(),
          Skuld.Comp.Types.computation(),
          reference(),
          Skuld.Comp.Env.t()
        ) ::
          t()
  def add_fiber(state, fiber_id, comp, boundary_id, env) do
    fiber_info = %{
      comp: comp,
      boundary_id: boundary_id,
      env: env
    }

    state
    |> put_in([Access.key(:fibers), fiber_id], fiber_info)
    |> update_in([Access.key(:run_queue)], &:queue.in({:fiber, fiber_id}, &1))
  end

  @doc """
  Get a fiber by ID.
  """
  @spec get_fiber(t(), reference()) :: fiber_info() | nil
  def get_fiber(state, fiber_id) do
    Map.get(state.fibers, fiber_id)
  end

  @doc """
  Remove a fiber from the fibers map (after it completes or is cancelled).
  """
  @spec remove_fiber(t(), reference()) :: t()
  def remove_fiber(state, fiber_id) do
    %{state | fibers: Map.delete(state.fibers, fiber_id)}
  end

  @doc """
  Record a fiber's completion result.

  Stores the result in fiber_results for waiters to retrieve.
  Also triggers wake check for any computations waiting on this fiber.
  """
  @spec record_fiber_result(t(), reference(), result()) ::
          {:woke, reference(), term(), t()} | {:waiting, t()}
  def record_fiber_result(state, fiber_id, result) do
    # Store the result
    state = %{state | fiber_results: Map.put(state.fiber_results, fiber_id, result)}

    # Remove from fibers map
    state = remove_fiber(state, fiber_id)

    # Check if anyone is waiting for this fiber via FiberTarget
    target_key = {:fiber, fiber_id}
    record_completion(state, target_key, result)
  end

  @doc """
  Check if a fiber result is available.
  """
  @spec get_fiber_result(t(), reference()) :: result() | nil
  def get_fiber_result(state, fiber_id) do
    Map.get(state.fiber_results, fiber_id)
  end
end
