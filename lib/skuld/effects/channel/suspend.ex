defmodule Skuld.Effects.Channel.Suspend do
  @moduledoc """
  Suspension value for channel operations.

  When a fiber performs a blocking channel operation (put on full buffer,
  take on empty buffer), it suspends with a ChannelSuspend struct. The
  FiberPool tracks these suspensions and resumes the fiber when the
  channel state changes.

  ## Fields

  - `channel_id` - The channel being operated on
  - `operation` - The operation type (`:put` or `:take`)
  - `item` - The item being put (only for `:put` operations)
  - `fiber_id` - The suspended fiber's ID
  - `resume` - Function to resume the fiber with the result
  """

  @type operation :: :put | :take

  @type t :: %__MODULE__{
          channel_id: reference(),
          operation: operation(),
          item: term() | nil,
          fiber_id: reference(),
          resume: (term() -> {term(), Skuld.Comp.Types.env()})
        }

  defstruct [:channel_id, :operation, :item, :fiber_id, :resume]

  @doc """
  Create a new suspension for a put operation.
  """
  @spec new_put(reference(), reference(), term(), (term() -> {term(), Skuld.Comp.Types.env()})) ::
          t()
  def new_put(channel_id, fiber_id, item, resume) do
    %__MODULE__{
      channel_id: channel_id,
      operation: :put,
      item: item,
      fiber_id: fiber_id,
      resume: resume
    }
  end

  @doc """
  Create a new suspension for a take operation.
  """
  @spec new_take(reference(), reference(), (term() -> {term(), Skuld.Comp.Types.env()})) :: t()
  def new_take(channel_id, fiber_id, resume) do
    %__MODULE__{
      channel_id: channel_id,
      operation: :take,
      item: nil,
      fiber_id: fiber_id,
      resume: resume
    }
  end
end

defimpl Skuld.Comp.ISentinel, for: Skuld.Effects.Channel.Suspend do
  def run(_suspend, _env) do
    raise "ChannelSuspend must be handled by FiberPool scheduler"
  end

  def run!(_suspend) do
    raise "ChannelSuspend must be handled by FiberPool scheduler"
  end

  def sentinel?(_), do: true

  def get_resume(%{resume: resume}), do: resume

  def with_resume(suspend, new_resume), do: %{suspend | resume: new_resume}

  def serializable_payload(%{channel_id: ch_id, operation: op, item: item, fiber_id: fid}) do
    %{channel_id: ch_id, operation: op, item: item, fiber_id: fid}
  end
end
