defmodule Skuld.Comp.IIntercept do
  @moduledoc """
  Behaviour for effects supporting local interception via catch clauses.

  This enables `catch` clauses in `comp` blocks to intercept effect-specific
  values. Currently used by:

  - `Throw` - intercepts errors for recovery
  - `Yield` - intercepts yields for response generation

  ## Example

      defmodule Throw do
        @behaviour Skuld.Comp.IIntercept

        @impl Skuld.Comp.IIntercept
        def intercept(comp, handler_fn) do
          catch_error(comp, handler_fn)
        end
      end

  ## Usage in comp blocks

      comp do
        x <- risky_operation()
        x * 2
      catch
        {Throw, :not_found} -> return(:default)  # calls Throw.intercept/2
      end

  The `handler_fn` receives the intercepted value (effect-specific) and
  must return a computation.

  ## See Also

  - `Skuld.Comp.IHandle` - for effect operation handling
  - `Skuld.Comp.IInstall` - for catch clause handler installation
  """

  @doc """
  Intercept effect operations locally within a computation.

  The `handler_fn` receives the intercepted value (effect-specific) and
  must return a computation:

  - For `Throw`: receives the error, returns recovery computation
  - For `Yield`: receives the yield value, returns computation producing resume input
  """
  @callback intercept(
              comp :: Skuld.Comp.Types.computation(),
              handler_fn :: (term() -> Skuld.Comp.Types.computation())
            ) :: Skuld.Comp.Types.computation()
end
