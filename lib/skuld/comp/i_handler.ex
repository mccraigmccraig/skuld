defmodule Skuld.Comp.IHandler do
  @moduledoc """
  **DEPRECATED** - Use the specific behaviours instead:

  - `Skuld.Comp.IHandle` - for effect operation handling (`handle/3`)
  - `Skuld.Comp.IIntercept` - for catch clause interception (`intercept/2`)
  - `Skuld.Comp.IInstall` - for catch clause handler installation (`__handle__/2`)

  ## Migration

  Replace:

      @behaviour Skuld.Comp.IHandler

  With the specific behaviours your effect needs:

      # Most effects need these two:
      @behaviour Skuld.Comp.IHandle    # if you have handle/3
      @behaviour Skuld.Comp.IInstall   # if you have __handle__/2

      # Only Throw and Yield need this:
      @behaviour Skuld.Comp.IIntercept # if you have intercept/2

  Update `@impl` tags accordingly:

      @impl Skuld.Comp.IHandle     # for handle/3
      @impl Skuld.Comp.IIntercept  # for intercept/2
      @impl Skuld.Comp.IInstall    # for __handle__/2

  ## Rationale

  Splitting into separate behaviours provides:
  - No `@optional_callbacks` - each behaviour is complete
  - Precise compile-time checking
  - Clearer intent - module declares exactly what it supports
  """

  @doc "Deprecated: Use Skuld.Comp.IHandle instead"
  @callback handle(args :: term(), env :: Skuld.Comp.Types.env(), k :: Skuld.Comp.Types.k()) ::
              {Skuld.Comp.Types.result(), Skuld.Comp.Types.env()}

  @doc "Deprecated: Use Skuld.Comp.IIntercept instead"
  @callback intercept(
              comp :: Skuld.Comp.Types.computation(),
              handler_fn :: (term() -> Skuld.Comp.Types.computation())
            ) :: Skuld.Comp.Types.computation()

  @doc "Deprecated: Use Skuld.Comp.IInstall instead"
  @callback __handle__(
              comp :: Skuld.Comp.Types.computation(),
              config :: term()
            ) :: Skuld.Comp.Types.computation()

  @optional_callbacks [handle: 3, intercept: 2, __handle__: 2]
end
