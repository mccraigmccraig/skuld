defmodule Skuld.Comp.UncaughtExit do
  @moduledoc """
  Exception raised when an Elixir `exit` is not caught within a Skuld computation.

  This wraps the exit reason so it can be re-raised with the original stacktrace.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "Uncaught exit in computation: #{inspect(reason)}"
  end
end
