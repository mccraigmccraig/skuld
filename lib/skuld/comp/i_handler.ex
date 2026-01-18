defmodule Skuld.Comp.IHandler do
  @moduledoc """
  Behaviour for effect handlers in Skuld.

  Implementing this behaviour provides:
  - LSP autocomplete for the `handle/3` callback signature
  - Compile-time warnings if the callback is missing or has wrong arity
  - Public `handle/3` function that can be referenced as `&Module.handle/3`

  ## Callbacks

  - `handle/3` (required) - how the effect responds to operations
  - `intercept/2` (optional) - allows local interception via catch clauses

  ## Example

      defmodule MyEffect do
        @behaviour Skuld.Comp.IHandler

        @impl Skuld.Comp.IHandler
        def handle(:op, env, k) do
          k.(:result, env)
        end
      end

      # Install handler:
      env |> Env.with_handler(MyEffect, &MyEffect.handle/3)

  ## Interception

  Effects can optionally support local interception via `catch` clauses in
  `comp` blocks. To enable this, implement the `intercept/2` callback:

      @impl Skuld.Comp.IHandler
      def intercept(comp, handler_fn) do
        # Wrap comp, intercepting effect operations and calling handler_fn
      end

  The `handler_fn` receives the intercepted value and returns a computation.
  See `Skuld.Effects.Throw.catch_error/2` and `Skuld.Effects.Yield.respond/2`
  for examples.
  """

  @doc """
  Handle an effect operation.

  Receives:
  - `args` - the operation arguments (e.g., `%Get{}`, `%Put{value: v}`)
  - `env` - the current environment
  - `k` - the continuation to invoke with the result

  Must return `{result, env}` - either by calling `k.(value, env)` or
  by returning a sentinel like `{%Skuld.Comp.Throw{}, env}`.
  """
  @callback handle(args :: term(), env :: Skuld.Comp.Types.env(), k :: Skuld.Comp.Types.k()) ::
              {Skuld.Comp.Types.result(), Skuld.Comp.Types.env()}

  @doc """
  Intercept effect operations locally within a computation.

  This enables `catch` clauses in `comp` blocks to handle this effect.
  The `handler_fn` receives the intercepted value (effect-specific) and
  must return a computation.

  For `Throw`: intercepts errors, handler returns recovery computation.
  For `Yield`: intercepts yields, handler returns computation producing resume input.
  """
  @callback intercept(
              comp :: Skuld.Comp.Types.computation(),
              handler_fn :: (term() -> Skuld.Comp.Types.computation())
            ) :: Skuld.Comp.Types.computation()

  @optional_callbacks [intercept: 2]
end
