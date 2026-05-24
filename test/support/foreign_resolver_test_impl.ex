defmodule Skuld.Test.Payload do
  @moduledoc false
  defstruct [:value]

  def new(value \\ :ok), do: %__MODULE__{value: value}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(_payload, suspends, continuation) do
      resolved = Map.new(suspends, &{&1.id, &1.payload.value})
      continuation.(resolved)
    end
  end
end
