defmodule Skuld.Syntax do
  @moduledoc """
  Unified syntax module providing do-notation macros for Skuld computations.

  ## Usage

      use Skuld.Syntax

      # Now you have access to:
      # - comp (inline computation block)
      # - defcomp, defcompp (function definitions)
      # - query (inline query block with automatic batching)
      # - defquery, defqueryp (query function definitions)

  ## Example

      use Skuld.Syntax
      alias Skuld.Effects.State

      comp do
        x <- State.get()
        y = x + 1
        _ <- State.put(y)
        y
      end

  ## Defining Functions

      defcomp increment() do
        x <- State.get()
        _ <- State.put(x + 1)
        x + 1
      end

      defcompp private_helper() do
        ctx <- Reader.ask()
        ctx.value
      end

  ## Query Functions

      defquery user_with_orders(id) do
        user <- Users.get_user(id)
        orders <- Orders.get_by_user(user.id)
        {user, orders}
      end

      defqueryp private_fetch(id) do
        data <- DataSource.fetch(id)
        data
      end

  ## Syntax Reference

  - `x <- effect()` - bind the result of an effectful computation
  - `x = expr` - pure variable binding (unchanged)
  - Last expression is auto-lifted if not already a computation

  ## Auto-Lifting

  Non-computation values are automatically wrapped in `Comp.pure/1`. This means:

  - Final expressions don't need wrapping: `x + 1` works as final line
  - `if` without `else` works: `_ <- if cond, do: effect()` (nil auto-lifted)
  - Any plain value in a bind position is treated as a pure computation

  ## See Also

  - `Skuld.Comp.CompBlock` - macro implementation details
  - `Skuld.Comp` - core computation primitives
  """

  defmacro __using__(_opts) do
    quote do
      import Skuld.Comp.CompBlock
      import Skuld.Query.QueryBlock
    end
  end
end
