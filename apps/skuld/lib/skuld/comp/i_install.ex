defmodule Skuld.Comp.IInstall do
  @moduledoc """
  Behaviour for effects supporting handler installation via catch clauses.

  This enables bare module patterns in `catch` clauses to install handlers:

      comp do
        x <- State.get()
        x * 2
      catch
        State -> 0   # calls State.__handle__(comp, 0)
      end

  ## Example

      defmodule State do
        @behaviour Skuld.Comp.IInstall

        @impl Skuld.Comp.IInstall
        def __handle__(comp, initial), do: with_handler(comp, initial)
      end

  ## Config Interpretation

  Effects can accept different config shapes:

      # Simple value
      def __handle__(comp, initial), do: with_handler(comp, initial)

      # Tuple with options
      def __handle__(comp, {initial, opts}), do: with_handler(comp, initial, opts)

      # Keyword options
      def __handle__(comp, opts) when is_list(opts), do: with_handler(comp, opts)

      # Ignored config (e.g., Throw just needs to be installed)
      def __handle__(comp, _config), do: with_handler(comp)

  ## See Also

  - `Skuld.Comp.IHandle` - for effect operation handling
  - `Skuld.Comp.IIntercept` - for catch clause value interception
  """

  @doc """
  Install a handler for this effect, wrapping the computation.

  The `config` term is effect-specific. Effects interpret it flexibly:

  - `State.__handle__(comp, initial)` - initial state value
  - `Reader.__handle__(comp, env_value)` - reader environment
  - `Throw.__handle__(comp, _)` - ignores config
  - `Fresh.__handle__(comp, :uuid7)` - handler variant selector
  """
  @callback __handle__(
              comp :: Skuld.Comp.Types.computation(),
              config :: term()
            ) :: Skuld.Comp.Types.computation()
end
