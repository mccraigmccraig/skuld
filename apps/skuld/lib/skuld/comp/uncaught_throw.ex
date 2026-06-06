defmodule Skuld.Comp.UncaughtThrow do
  @moduledoc """
  Exception raised when an Elixir `throw` is not caught within a Skuld computation.

  This wraps the thrown value so it can be re-raised with the original stacktrace.
  """

  defexception [:value]

  @impl true
  def message(%__MODULE__{value: value}) do
    "Uncaught throw in computation: #{inspect(value)}"
  end
end
