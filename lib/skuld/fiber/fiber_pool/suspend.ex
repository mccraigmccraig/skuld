defmodule Skuld.Fiber.FiberPool.Suspend do
  @moduledoc """
  Suspension sentinel for FiberPool operations.

  When a fiber performs an await operation, the handler yields this sentinel
  to the scheduler. The scheduler then handles the await by tracking the
  suspension and resuming when results are available.

  This is similar to how Async uses AwaitSuspend, but simplified for the
  new FiberPool design.
  """

  alias Skuld.Comp.ISentinel
  alias Skuld.Fiber.Handle

  @type await_mode :: :one | :all | :any

  @type t :: %__MODULE__{
          op: :await,
          handles: [Handle.t()],
          mode: await_mode(),
          resume: (term() -> {term(), Skuld.Comp.Types.env()}),
          consume_ids: [reference()]
        }

  defstruct [:op, :handles, :mode, :resume, consume_ids: []]

  @doc """
  Create an await suspension for a single handle.
  """
  @spec await_one(Handle.t(), (term() -> {term(), Skuld.Comp.Types.env()}), keyword()) :: t()
  def await_one(handle, resume, opts \\ []) do
    consume = Keyword.get(opts, :consume, false)

    %__MODULE__{
      op: :await,
      handles: [handle],
      mode: :one,
      resume: resume,
      consume_ids: if(consume, do: [handle.id], else: [])
    }
  end

  @doc """
  Create an await suspension for all handles.
  """
  @spec await_all([Handle.t()], (term() -> {term(), Skuld.Comp.Types.env()})) :: t()
  def await_all(handles, resume) do
    %__MODULE__{
      op: :await,
      handles: handles,
      mode: :all,
      resume: resume
    }
  end

  @doc """
  Create an await suspension for any handle.
  """
  @spec await_any([Handle.t()], (term() -> {term(), Skuld.Comp.Types.env()})) :: t()
  def await_any(handles, resume) do
    %__MODULE__{
      op: :await,
      handles: handles,
      mode: :any,
      resume: resume
    }
  end

  # ISentinel implementation - FiberPoolSuspend bypasses leave_scope
  defimpl ISentinel do
    def run(suspend, _env) do
      raise "FiberPool.Suspend must be handled by the FiberPool scheduler, got: #{inspect(suspend)}"
    end

    def run!(_suspend) do
      raise "FiberPool.Suspend must be handled by the FiberPool scheduler"
    end

    def sentinel?(_), do: true

    def get_resume(%{resume: resume}), do: resume

    def with_resume(suspend, new_resume), do: %{suspend | resume: new_resume}

    def serializable_payload(%{op: op, mode: mode, handles: handles}) do
      %{op: op, mode: mode, handle_ids: Enum.map(handles, & &1.id)}
    end
  end
end
