defmodule Skuld.Test.ForeignResolver do
  @moduledoc """
  Test implementation of `Skuld.ForeignResolver` that resolves all foreign
  suspensions immediately with `:ok`. Useful for unit tests that don't need
  actual async resolution.
  """

  defstruct []

  @doc false
  def new, do: %__MODULE__{}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(_resolver, suspends, continuation) do
      resolved = Map.new(suspends, &{&1.id, :ok})
      continuation.(resolved)
    end
  end
end
