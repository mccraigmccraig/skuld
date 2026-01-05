defmodule Skuld.Comp.BaseOps do
  @moduledoc """
  Base operations automatically imported into `comp` blocks.

  Currently provides:
  - `return/1` - lift a pure value into a computation (delegates to `Skuld.Comp.return/1`)
  """

  @doc """
  Lift a pure value into a computation.

  This delegates to `Skuld.Comp.return/1`, provided for ergonomic use
  in `comp` blocks where `return(value)` reads more naturally.

  ## Example

      comp do
        x <- State.get()
        return(x + 1)
      end
  """
  @spec return(term()) :: Skuld.Comp.Types.computation()
  def return(x), do: Skuld.Comp.return(x)
end
