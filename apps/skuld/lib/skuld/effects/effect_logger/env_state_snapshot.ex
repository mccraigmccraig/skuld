# A serializable snapshot of `env.state` for cold resume.
#
# All env.state keys are strings, so they pass through JSON natively
# without needing encode/decode conversion.
#
# ## Filtering
#
# EffectLogger's internal state keys are filtered out when capturing:
# - Log state key: would create circular reference (log contains snapshot)
# - Resume value key: only needed during active resume, not for persistence
# - State keys filter: internal config that doesn't survive JSON round-trip
#
# ## Example
#
#     env_state = %{
#       "Elixir.Skuld.Effects.State" => 42,
#       "Elixir.Skuld.Effects.EffectLogger::log" => %Log{...}
#     }
#
#     snapshot = EnvStateSnapshot.capture(env_state)
#     # => %EnvStateSnapshot{entries: %{"Elixir.Skuld.Effects.State" => 42}}
#
#     restored = EnvStateSnapshot.restore(snapshot)
#     # => %{"Elixir.Skuld.Effects.State" => 42}
defmodule Skuld.Effects.EffectLogger.EnvStateSnapshot do
  @moduledoc false

  alias Skuld.Comp.SerializableStruct

  @effect_logger_state_key "Elixir.Skuld.Effects.EffectLogger::log"
  @resume_value_key "Elixir.Skuld.Effects.EffectLogger::resume_value"
  @state_keys_key "Elixir.Skuld.Effects.EffectLogger::state_keys"

  defstruct entries: %{}

  @type t :: %__MODULE__{
          entries: %{String.t() => term()}
        }

  @doc """
  Capture a snapshot of env.state for serialization.

  Filters out EffectLogger's internal state. All keys are already
  strings so no conversion is needed.

  ## Options

  - `:state_keys` - List of state keys to include. Default `:all` captures everything.
    Keys should be in the format used in env.state (strings).

  ## Examples

      # Capture all state
      EnvStateSnapshot.capture(env_state)

      # Capture only specific State effect keys
      EnvStateSnapshot.capture(env_state, state_keys: [
        State.state_key(MyApp.Counter)
      ])
  """
  @spec capture(map(), keyword()) :: t()
  def capture(env_state, opts \\ [])

  def capture(env_state, opts) when is_map(env_state) do
    state_keys = Keyword.get(opts, :state_keys, :all)

    entries =
      env_state
      |> Enum.reject(fn {key, _value} ->
        key == @effect_logger_state_key or key == @resume_value_key or key == @state_keys_key
      end)
      |> Enum.filter(fn {key, _value} ->
        case state_keys do
          :all -> true
          nil -> true
          keys when is_list(keys) -> key in keys
        end
      end)
      |> Enum.map(fn {key, value} ->
        {key, encode_value(value)}
      end)
      |> Map.new()

    %__MODULE__{entries: entries}
  end

  @doc """
  Restore env.state from a snapshot.

  Keys are already strings, so they pass through unchanged.
  """
  @spec restore(t()) :: map()
  def restore(%__MODULE__{entries: entries}) do
    entries
    |> Enum.map(fn {key, value} ->
      {key, decode_value(value)}
    end)
    |> Map.new()
  end

  @doc """
  Reconstruct from decoded JSON map.
  """
  @spec from_json(map()) :: t()
  def from_json(map) when is_map(map) do
    entries =
      (map["entries"] || %{})
      |> Enum.map(fn {k, v} ->
        {k, decode_value(v)}
      end)
      |> Map.new()

    %__MODULE__{entries: entries}
  end

  # Encode a value for JSON serialization
  defp encode_value(%_{} = struct) do
    SerializableStruct.encode(struct)
  end

  defp encode_value(value), do: value

  # Decode a value from JSON
  defp decode_value(map) when is_map(map) do
    if Map.has_key?(map, "__struct__") or Map.has_key?(map, :__struct__) do
      SerializableStruct.decode(map)
    else
      map
    end
  end

  defp decode_value(value), do: value
end

defimpl Jason.Encoder, for: Skuld.Effects.EffectLogger.EnvStateSnapshot do
  alias Skuld.Comp.SerializableStruct

  def encode(value, opts) do
    value
    |> SerializableStruct.encode()
    |> Jason.Encode.map(opts)
  end
end
