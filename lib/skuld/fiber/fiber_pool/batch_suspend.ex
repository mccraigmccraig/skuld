defmodule Skuld.Fiber.FiberPool.BatchSuspend do
  @moduledoc """
  Suspension value for batchable operations.

  When a fiber performs a batchable operation (like DB.fetch), it suspends with
  a BatchSuspend struct. The FiberPool scheduler collects these suspensions,
  groups them by batch_key, and executes them together.

  ## Fields

  - `op` - The operation struct (must implement IBatchable)
  - `resume` - Function to resume the fiber with the result
  - `request_id` - Unique ID for matching results back to this request
  """

  @type t :: %__MODULE__{
          op: term(),
          resume: (term() -> {term(), Skuld.Comp.Types.env()}),
          request_id: reference()
        }

  defstruct [:op, :resume, :request_id]

  @doc """
  Create a new BatchSuspend.

  ## Parameters

  - `op` - The batchable operation struct
  - `resume` - Function called with the result to resume the fiber
  - `request_id` - Optional request ID (generated if not provided)
  """
  @spec new(term(), (term() -> {term(), Skuld.Comp.Types.env()}), reference() | nil) :: t()
  def new(op, resume, request_id \\ nil) do
    %__MODULE__{
      op: op,
      resume: resume,
      request_id: request_id || make_ref()
    }
  end
end

defimpl Skuld.Comp.ISentinel, for: Skuld.Fiber.FiberPool.BatchSuspend do
  def run(_suspend, _env) do
    raise "BatchSuspend must be handled by FiberPool scheduler"
  end

  def run!(_suspend) do
    raise "BatchSuspend must be handled by FiberPool scheduler"
  end

  def sentinel?(_), do: true

  def get_resume(%{resume: resume}), do: resume

  def with_resume(suspend, new_resume), do: %{suspend | resume: new_resume}

  def serializable_payload(%{op: op, request_id: id}) do
    %{op: op, request_id: id}
  end
end
