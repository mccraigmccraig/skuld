defmodule Skuld.Data.Change do
  @moduledoc """
  Represents a state change with old and new values.

  Used by State.put and TaggedState.put to return both the previous
  and updated state values. JSON-serializable for EffectLogger compatibility.

  ## Example

      %Change{old: 0, new: 42}
  """

  @enforce_keys [:old, :new]
  defstruct [:old, :new]

  @type t :: %__MODULE__{
          old: any(),
          new: any()
        }

  @doc """
  Create a new Change struct.
  """
  @spec new(any(), any()) :: t()
  def new(old, new) do
    %__MODULE__{old: old, new: new}
  end

  @doc """
  Reconstruct a Change from decoded JSON map.
  """
  @spec from_json(map()) :: t()
  def from_json(map) when is_map(map) do
    %__MODULE__{
      old: map["old"] || map[:old],
      new: map["new"] || map[:new]
    }
  end
end

defimpl Jason.Encoder, for: Skuld.Data.Change do
  def encode(value, opts) do
    value
    |> Skuld.Comp.SerializableStruct.encode()
    |> Jason.Encode.map(opts)
  end
end
