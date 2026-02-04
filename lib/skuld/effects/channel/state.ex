defmodule Skuld.Effects.Channel.State do
  @moduledoc """
  Internal state for a Channel.

  Channels are bounded buffers with suspend semantics:
  - `put` suspends when buffer is full (backpressure)
  - `take` suspends when buffer is empty (flow control)
  - Error state propagates to all consumers (sticky error)

  ## Fields

  - `id` - Unique channel identifier (reference)
  - `capacity` - Maximum buffer size (positive integer)
  - `buffer` - Queue of buffered items
  - `status` - `:open`, `:closed`, or `{:error, reason}`
  - `waiting_puts` - List of `{fiber_id, item}` waiting for space
  - `waiting_takes` - List of `fiber_id` waiting for items

  ## Status Transitions

  ```
      ┌─────────┐
      │  :open  │ ───── put/take work normally
      └────┬────┘
           │
      close() or error()
           │
      ┌────┴─────────────────┐
      │                      │
      ▼                      ▼
  ┌─────────┐        ┌──────────────────┐
  │ :closed │        │ {:error, reason} │
  └─────────┘        └──────────────────┘
      │                      │
      ▼                      ▼
  take returns           take ALWAYS returns
  :closed when           {:error, reason}
  buffer empty           (error is sticky!)
  ```
  """

  @type channel_id :: reference()
  @type fiber_id :: reference()
  @type status :: :open | :closed | {:error, term()}

  @type waiting_put :: {fiber_id(), term()}
  @type waiting_take :: fiber_id()

  @type t :: %__MODULE__{
          id: channel_id(),
          capacity: non_neg_integer(),
          buffer: :queue.queue(term()),
          status: status(),
          waiting_puts: [waiting_put()],
          waiting_takes: [waiting_take()]
        }

  defstruct [
    :id,
    :capacity,
    :buffer,
    :status,
    :waiting_puts,
    :waiting_takes
  ]

  @doc """
  Create a new channel state with the given capacity.

  A capacity of 0 creates a rendezvous/synchronous channel where put always
  blocks until there is a matching take (direct handoff, no buffering).
  """
  @spec new(non_neg_integer()) :: t()
  def new(capacity) when is_integer(capacity) and capacity >= 0 do
    %__MODULE__{
      id: make_ref(),
      capacity: capacity,
      buffer: :queue.new(),
      status: :open,
      waiting_puts: [],
      waiting_takes: []
    }
  end

  #############################################################################
  ## Buffer Operations
  #############################################################################

  @doc """
  Check if the buffer is full.
  """
  @spec buffer_full?(t()) :: boolean()
  def buffer_full?(state) do
    :queue.len(state.buffer) >= state.capacity
  end

  @doc """
  Check if the buffer is empty.
  """
  @spec buffer_empty?(t()) :: boolean()
  def buffer_empty?(state) do
    :queue.is_empty(state.buffer)
  end

  @doc """
  Get the number of items in the buffer.
  """
  @spec buffer_size(t()) :: non_neg_integer()
  def buffer_size(state) do
    :queue.len(state.buffer)
  end

  @doc """
  Add an item to the buffer (back of queue).
  """
  @spec enqueue(t(), term()) :: t()
  def enqueue(state, item) do
    %{state | buffer: :queue.in(item, state.buffer)}
  end

  @doc """
  Remove and return the first item from the buffer.

  Returns `{:ok, item, state}` or `:empty`.
  """
  @spec dequeue(t()) :: {:ok, term(), t()} | :empty
  def dequeue(state) do
    case :queue.out(state.buffer) do
      {{:value, item}, buffer} ->
        {:ok, item, %{state | buffer: buffer}}

      {:empty, _buffer} ->
        :empty
    end
  end

  @doc """
  Peek at the first item without removing it.

  Returns `{:ok, item}` or `:empty`.
  """
  @spec peek(t()) :: {:ok, term()} | :empty
  def peek(state) do
    case :queue.peek(state.buffer) do
      {:value, item} -> {:ok, item}
      :empty -> :empty
    end
  end

  #############################################################################
  ## Waiting Put Management
  #############################################################################

  @doc """
  Add a fiber to the waiting puts list.
  """
  @spec add_waiting_put(t(), fiber_id(), term()) :: t()
  def add_waiting_put(state, fiber_id, item) do
    %{state | waiting_puts: state.waiting_puts ++ [{fiber_id, item}]}
  end

  @doc """
  Check if there are fibers waiting to put.
  """
  @spec has_waiting_puts?(t()) :: boolean()
  def has_waiting_puts?(state) do
    state.waiting_puts != []
  end

  @doc """
  Pop the first waiting put.

  Returns `{:ok, {fiber_id, item}, state}` or `:empty`.
  """
  @spec pop_waiting_put(t()) :: {:ok, waiting_put(), t()} | :empty
  def pop_waiting_put(state) do
    case state.waiting_puts do
      [first | rest] ->
        {:ok, first, %{state | waiting_puts: rest}}

      [] ->
        :empty
    end
  end

  @doc """
  Get all waiting puts and clear the list.
  """
  @spec pop_all_waiting_puts(t()) :: {[waiting_put()], t()}
  def pop_all_waiting_puts(state) do
    {state.waiting_puts, %{state | waiting_puts: []}}
  end

  #############################################################################
  ## Waiting Take Management
  #############################################################################

  @doc """
  Add a fiber to the waiting takes list.
  """
  @spec add_waiting_take(t(), fiber_id()) :: t()
  def add_waiting_take(state, fiber_id) do
    %{state | waiting_takes: state.waiting_takes ++ [fiber_id]}
  end

  @doc """
  Check if there are fibers waiting to take.
  """
  @spec has_waiting_takes?(t()) :: boolean()
  def has_waiting_takes?(state) do
    state.waiting_takes != []
  end

  @doc """
  Pop the first waiting take.

  Returns `{:ok, fiber_id, state}` or `:empty`.
  """
  @spec pop_waiting_take(t()) :: {:ok, waiting_take(), t()} | :empty
  def pop_waiting_take(state) do
    case state.waiting_takes do
      [first | rest] ->
        {:ok, first, %{state | waiting_takes: rest}}

      [] ->
        :empty
    end
  end

  @doc """
  Get all waiting takes and clear the list.
  """
  @spec pop_all_waiting_takes(t()) :: {[waiting_take()], t()}
  def pop_all_waiting_takes(state) do
    {state.waiting_takes, %{state | waiting_takes: []}}
  end

  #############################################################################
  ## Status Management
  #############################################################################

  @doc """
  Check if the channel is open.
  """
  @spec open?(t()) :: boolean()
  def open?(state) do
    state.status == :open
  end

  @doc """
  Check if the channel is closed.
  """
  @spec closed?(t()) :: boolean()
  def closed?(state) do
    state.status == :closed
  end

  @doc """
  Check if the channel is in error state.
  """
  @spec errored?(t()) :: boolean()
  def errored?(state) do
    match?({:error, _}, state.status)
  end

  @doc """
  Close the channel (normal completion).

  Only transitions from `:open` state.
  """
  @spec close(t()) :: t()
  def close(state) do
    case state.status do
      :open -> %{state | status: :closed}
      _ -> state
    end
  end

  @doc """
  Put the channel into error state.

  Only transitions from `:open` state (first error wins).
  """
  @spec error(t(), term()) :: t()
  def error(state, reason) do
    case state.status do
      :open -> %{state | status: {:error, reason}}
      _ -> state
    end
  end

  #############################################################################
  ## Inspection
  #############################################################################

  @doc """
  Get channel statistics for debugging/metrics.
  """
  @spec stats(t()) :: map()
  def stats(state) do
    %{
      id: state.id,
      capacity: state.capacity,
      buffer_size: buffer_size(state),
      status: state.status,
      waiting_puts: length(state.waiting_puts),
      waiting_takes: length(state.waiting_takes)
    }
  end
end
