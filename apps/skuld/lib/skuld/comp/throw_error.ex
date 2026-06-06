# credo:disable-for-this-file Credo.Check.Consistency.ExceptionNames
# Naming is intentional: ThrowError is for Skuld's Throw.throw/1 effect,
# while UncaughtThrow/UncaughtExit are for Elixir's native throw/exit.
defmodule Skuld.Comp.ThrowError do
  @moduledoc """
  Exception raised when a Skuld computation throws via `Throw.throw/1`
  and the error is not caught.

  This is distinct from Elixir's native exceptions - it represents an
  intentional error thrown using Skuld's effect system.

  ## Example

      comp do
        _ <- Throw.throw(:not_found)
        :ok
      end
      |> Throw.with_handler()
      |> Comp.run!()
      # => raises %ThrowError{error: :not_found}
  """

  defexception [:error]

  @impl true
  def message(%__MODULE__{error: error}) do
    "Computation threw: #{inspect(error)}"
  end
end
