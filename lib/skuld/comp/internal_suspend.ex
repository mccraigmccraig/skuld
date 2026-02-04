defmodule Skuld.Comp.InternalSuspend do
  @moduledoc """
  Internal suspension for Env-aware code.

  Unlike `Comp.ExternalSuspend` (which closes over env for external callbacks),
  this suspension receives env at resume time, allowing callers to
  supply an updated env when resuming.

  ## Two Kinds of Suspension

  **External suspension (`Comp.ExternalSuspend`)**:
  - `resume :: (val) -> {result, env}`
  - Closes over env at suspension point
  - For passing to external code that doesn't understand Skuld's env threading

  **Internal suspension (`Comp.InternalSuspend`)**:
  - `resume :: (val, env) -> {result, env}`
  - Does NOT close over env - receives it at resume time
  - For schedulers/handlers that need to thread updated env through suspensions

  ## Payload Types

  The `payload` field contains a struct that identifies the kind of suspension:
  - `Batch` - batchable operations (DB fetches, etc.)
  - `Channel` - channel put/take operations
  - `Await` - fiber await operations
  """

  alias Skuld.Comp.Types
  alias Skuld.Fiber.Handle

  @type payload :: __MODULE__.Batch.t() | __MODULE__.Channel.t() | __MODULE__.Await.t()

  @type t :: %__MODULE__{
          resume: (term(), Types.env() -> {term(), Types.env()}),
          payload: payload()
        }

  defstruct [:resume, :payload]

  #############################################################################
  ## Payload Structs
  #############################################################################

  # Payload for batch operation suspensions.
  #
  # When a fiber performs a batchable operation (like DB.fetch), it suspends
  # with this payload. The scheduler collects these suspensions, groups them
  # by batch_key, and executes them together.
  defmodule Batch do
    @moduledoc false

    @type t :: %__MODULE__{
            op: term(),
            request_id: reference()
          }

    defstruct [:op, :request_id]
  end

  # Payload for channel operation suspensions.
  #
  # When a fiber performs a blocking channel operation (put on full buffer,
  # take on empty buffer), it suspends with this payload. The scheduler
  # resumes the fiber when the channel state changes.
  defmodule Channel do
    @moduledoc false

    @type operation :: :put | :take

    @type t :: %__MODULE__{
            channel_id: reference(),
            operation: operation(),
            item: term() | nil
          }

    defstruct [:channel_id, :operation, :item]
  end

  # Payload for fiber await suspensions.
  #
  # When a fiber awaits other fibers, it suspends with this payload.
  # The scheduler resumes the fiber when the awaited fibers complete.
  defmodule Await do
    @moduledoc false

    @type mode :: :one | :all | :any

    @type t :: %__MODULE__{
            handles: [Handle.t()],
            mode: mode(),
            consume_ids: [reference()]
          }

    defstruct [:handles, :mode, consume_ids: []]
  end

  #############################################################################
  ## Constructors
  #############################################################################

  @doc """
  Create a batch operation suspension.
  """
  @spec batch(term(), reference(), Types.k()) :: t()
  def batch(op, request_id, resume) do
    %__MODULE__{
      resume: resume,
      payload: %Batch{op: op, request_id: request_id}
    }
  end

  @doc """
  Create a channel put suspension.
  """
  @spec channel_put(reference(), term(), Types.k()) :: t()
  def channel_put(channel_id, item, resume) do
    %__MODULE__{
      resume: resume,
      payload: %Channel{channel_id: channel_id, operation: :put, item: item}
    }
  end

  @doc """
  Create a channel take suspension.
  """
  @spec channel_take(reference(), Types.k()) :: t()
  def channel_take(channel_id, resume) do
    %__MODULE__{
      resume: resume,
      payload: %Channel{channel_id: channel_id, operation: :take, item: nil}
    }
  end

  @doc """
  Create an await-one suspension.
  """
  @spec await_one(Handle.t(), Types.k(), keyword()) :: t()
  def await_one(handle, resume, opts \\ []) do
    consume = Keyword.get(opts, :consume, false)

    %__MODULE__{
      resume: resume,
      payload: %Await{
        handles: [handle],
        mode: :one,
        consume_ids: if(consume, do: [handle.id], else: [])
      }
    }
  end

  @doc """
  Create an await-all suspension.
  """
  @spec await_all([Handle.t()], Types.k()) :: t()
  def await_all(handles, resume) do
    %__MODULE__{
      resume: resume,
      payload: %Await{handles: handles, mode: :all, consume_ids: []}
    }
  end

  @doc """
  Create an await-any suspension.
  """
  @spec await_any([Handle.t()], Types.k()) :: t()
  def await_any(handles, resume) do
    %__MODULE__{
      resume: resume,
      payload: %Await{handles: handles, mode: :any, consume_ids: []}
    }
  end
end

defimpl Skuld.Comp.ISentinel, for: Skuld.Comp.InternalSuspend do
  alias Skuld.Comp.InternalSuspend.Await
  alias Skuld.Comp.InternalSuspend.Batch
  alias Skuld.Comp.InternalSuspend.Channel

  def run(_suspend, _env) do
    raise "InternalSuspend must be handled by a scheduler"
  end

  def run!(_suspend) do
    raise "InternalSuspend must be handled by a scheduler"
  end

  def sentinel?(_), do: true
  def suspend?(_), do: true
  def error?(_), do: false

  def serializable_payload(%{payload: %Batch{op: op, request_id: id}}) do
    %{type: :batch, op: op, request_id: id}
  end

  def serializable_payload(%{payload: %Channel{channel_id: ch_id, operation: op, item: item}}) do
    %{type: :channel, channel_id: ch_id, operation: op, item: item}
  end

  def serializable_payload(%{payload: %Await{handles: handles, mode: mode}}) do
    %{type: :await, handle_ids: Enum.map(handles, & &1.id), mode: mode}
  end
end
