defmodule Skuld.Effects.NonBlockingAsync.Scheduler.State do
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

  alias Skuld.Effects.NonBlockingAsync.AwaitRequest
  alias AwaitRequest.Target

  defstruct [
    :suspended,
    :waiting_for,
    :run_queue,
    :completed,
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

  @type ready_item :: {reference(), term()}

  @type t :: %__MODULE__{
          suspended: %{reference() => suspension_info()},
          waiting_for: %{target_key() => reference()},
          run_queue: :queue.queue(ready_item()),
          completed: %{reference() => term()},
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
      opts: opts
    }
  end

  @doc """
  Add a suspended computation to track.

  Creates the waiting_for reverse index entries for fast completion lookup.
  """
  @spec add_suspension(t(), reference(), AwaitRequest.t(), (term() -> term())) :: t()
  def add_suspension(state, request_id, request, resume) do
    suspension_info = %{
      resume: resume,
      request: request,
      collected: %{},
      suspended_at: System.monotonic_time(:millisecond)
    }

    # Build reverse index: target_key => request_id
    target_keys = Enum.map(request.targets, &Target.key/1)

    waiting_for =
      Enum.reduce(target_keys, state.waiting_for, fn key, acc ->
        Map.put(acc, key, request_id)
      end)

    %{
      state
      | suspended: Map.put(state.suspended, request_id, suspension_info),
        waiting_for: waiting_for
    }
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
  """
  @spec record_completion(t(), target_key(), result()) ::
          {:woke, reference(), term(), t()} | {:waiting, t()}
  def record_completion(state, target_key, result) do
    case Map.get(state.waiting_for, target_key) do
      nil ->
        # No one waiting for this target (already completed or cancelled)
        {:waiting, state}

      request_id ->
        case Map.get(state.suspended, request_id) do
          nil ->
            # Suspension was already removed
            {:waiting, state}

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

  Returns `{:ok, {request_id, resume, results}, state}` or `{:empty, state}`.
  """
  @spec dequeue_one(t()) :: {:ok, {reference(), (term() -> term()), term()}, t()} | {:empty, t()}
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
  """
  @spec record_completed(t(), reference(), term()) :: t()
  def record_completed(state, request_id, result) do
    %{state | completed: Map.put(state.completed, request_id, result)}
  end

  @doc """
  Check if any computations are still active (suspended or in run queue).
  """
  @spec active?(t()) :: boolean()
  def active?(state) do
    map_size(state.suspended) > 0 or not :queue.is_empty(state.run_queue)
  end

  @doc """
  Get counts for debugging/metrics.
  """
  @spec counts(t()) :: %{
          suspended: non_neg_integer(),
          ready: non_neg_integer(),
          completed: non_neg_integer()
        }
  def counts(state) do
    %{
      suspended: map_size(state.suspended),
      ready: :queue.len(state.run_queue),
      completed: map_size(state.completed)
    }
  end
end
