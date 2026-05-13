# Channel state registry threaded through all fibers in a FiberPool.
#
# Stores channel states under a single key in state.env_state so they
# persist across fiber executions.
#
# ## Key
#
# Use `env_key/0` to get the key under which this struct is stored in env.state.
defmodule Skuld.FiberPool.ChannelCoordinationState do
  @moduledoc false

  alias Skuld.Effects.Channel.ChannelState

  @doc """
  The key under which ChannelCoordinationState is stored in env.state.
  """
  @spec env_key() :: module()
  def env_key, do: __MODULE__

  @type t :: %__MODULE__{
          channel_states: %{reference() => ChannelState.t()}
        }

  defstruct channel_states: %{}

  @doc """
  Create a new empty ChannelCoordinationState.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  #############################################################################
  ## Channel State Management
  #############################################################################

  @doc """
  Register a new channel. Called when Channel.new() creates a channel.
  """
  @spec register_channel(t(), ChannelState.t()) :: t()
  def register_channel(%__MODULE__{channel_states: channels} = env_state, state) do
    %{env_state | channel_states: Map.put(channels, state.id, state)}
  end

  @doc """
  Get a channel's state by ID. Raises if channel not found.
  """
  @spec get_channel!(t(), reference()) :: ChannelState.t()
  def get_channel!(%__MODULE__{channel_states: channels}, channel_id) do
    case Map.get(channels, channel_id) do
      nil -> raise "Channel not found: #{inspect(channel_id)}"
      state -> state
    end
  end

  @doc """
  Get a channel's state by ID. Returns nil if not found.
  """
  @spec get_channel(t(), reference()) :: ChannelState.t() | nil
  def get_channel(%__MODULE__{channel_states: channels}, channel_id) do
    Map.get(channels, channel_id)
  end

  @doc """
  Update a channel's state. Called after channel operations modify state.
  """
  @spec put_channel(t(), reference(), ChannelState.t()) :: t()
  def put_channel(%__MODULE__{channel_states: channels} = env_state, channel_id, state) do
    %{env_state | channel_states: Map.put(channels, channel_id, state)}
  end
end
