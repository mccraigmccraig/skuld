defmodule Skuld.Fiber.FiberPool.EnvState do
  @moduledoc """
  Shared state threaded through all fibers in a FiberPool.

  This struct consolidates the loose keys that were previously stored
  separately in `env.state` for coordination between Scheduler and Channel:

  - `current_fiber_id` - Set by Scheduler before running each fiber,
    read by Channel to know which fiber is executing
  - `channel_wakes` - Wake requests accumulated by Channel operations,
    consumed by Scheduler to resume suspended fibers
  - `channel_states` - Map of channel_id to Channel.State for all channels

  ## Lifecycle

  This state is stored under a single key in `state.env_state` and threaded
  to all fibers. Unlike `PendingWork` which is fiber-local and cleared,
  this state persists and is shared across all fiber executions.

  ## Key

  Use `env_key/0` to get the key under which this struct is stored in env.state.
  """

  alias Skuld.Effects.Channel

  @doc """
  The key under which EnvState is stored in env.state.
  """
  @spec env_key() :: module()
  def env_key, do: __MODULE__

  @type fiber_id :: reference()

  @type t :: %__MODULE__{
          current_fiber_id: fiber_id() | nil,
          channel_wakes: [{fiber_id(), term()}],
          channel_states: %{fiber_id() => Channel.State.t()}
        }

  defstruct current_fiber_id: nil,
            channel_wakes: [],
            channel_states: %{}

  @doc """
  Create a new empty EnvState.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  #############################################################################
  ## Fiber ID Management (Scheduler sets, Channel reads)
  #############################################################################

  @doc """
  Set the current fiber ID. Called by Scheduler before running a fiber.
  """
  @spec set_fiber_id(t(), fiber_id()) :: t()
  def set_fiber_id(%__MODULE__{} = env_state, fiber_id) do
    %{env_state | current_fiber_id: fiber_id}
  end

  @doc """
  Get the current fiber ID. Called by Channel to know which fiber is executing.

  Raises if no fiber ID is set.
  """
  @spec get_fiber_id!(t()) :: fiber_id()
  def get_fiber_id!(%__MODULE__{current_fiber_id: nil}) do
    raise "No fiber ID in environment - Channel operations must run within a FiberPool"
  end

  def get_fiber_id!(%__MODULE__{current_fiber_id: fid}), do: fid

  #############################################################################
  ## Channel Wake Management (Channel writes, Scheduler consumes)
  #############################################################################

  @doc """
  Add a channel wake request. Called by Channel when an operation can
  satisfy a waiting fiber.

  The Scheduler will process these wakes and resume the fibers.
  """
  @spec add_channel_wake(t(), fiber_id(), term()) :: t()
  def add_channel_wake(%__MODULE__{channel_wakes: wakes} = env_state, fiber_id, result) do
    %{env_state | channel_wakes: [{fiber_id, result} | wakes]}
  end

  @doc """
  Pop all channel wakes for processing. Called by Scheduler.

  Returns `{wakes, updated_env_state}` where wakes is the list of
  `{fiber_id, result}` tuples and the env_state has an empty wakes list.
  """
  @spec pop_channel_wakes(t()) :: {[{fiber_id(), term()}], t()}
  def pop_channel_wakes(%__MODULE__{channel_wakes: wakes} = env_state) do
    {wakes, %{env_state | channel_wakes: []}}
  end

  @doc """
  Check if there are any pending channel wakes.
  """
  @spec has_channel_wakes?(t()) :: boolean()
  def has_channel_wakes?(%__MODULE__{channel_wakes: []}), do: false
  def has_channel_wakes?(%__MODULE__{}), do: true

  #############################################################################
  ## Channel State Management (Channel reads/writes)
  #############################################################################

  @doc """
  Register a new channel. Called when Channel.new() creates a channel.
  """
  @spec register_channel(t(), Channel.State.t()) :: t()
  def register_channel(%__MODULE__{channel_states: channels} = env_state, state) do
    %{env_state | channel_states: Map.put(channels, state.id, state)}
  end

  @doc """
  Get a channel's state by ID. Raises if channel not found.
  """
  @spec get_channel!(t(), reference()) :: Channel.State.t()
  def get_channel!(%__MODULE__{channel_states: channels}, channel_id) do
    case Map.get(channels, channel_id) do
      nil -> raise "Channel not found: #{inspect(channel_id)}"
      state -> state
    end
  end

  @doc """
  Get a channel's state by ID. Returns nil if not found.
  """
  @spec get_channel(t(), reference()) :: Channel.State.t() | nil
  def get_channel(%__MODULE__{channel_states: channels}, channel_id) do
    Map.get(channels, channel_id)
  end

  @doc """
  Update a channel's state. Called after channel operations modify state.
  """
  @spec put_channel(t(), reference(), Channel.State.t()) :: t()
  def put_channel(%__MODULE__{channel_states: channels} = env_state, channel_id, state) do
    %{env_state | channel_states: Map.put(channels, channel_id, state)}
  end
end
