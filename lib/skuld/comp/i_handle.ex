defmodule Skuld.Comp.IHandle do
  @moduledoc """
  Behaviour for effect operation handlers.

  Implementing this behaviour provides:
  - LSP autocomplete for the `handle/3` callback signature
  - Compile-time warnings if the callback is missing or has wrong arity
  - Public `handle/3` function that can be referenced as `&Module.handle/3`

  ## Example

      defmodule MyEffect do
        @behaviour Skuld.Comp.IHandle

        @impl Skuld.Comp.IHandle
        def handle(%Get{}, env, k) do
          value = Env.get_state(env, @state_key)
          k.(value, env)
        end

        @impl Skuld.Comp.IHandle
        def handle(%Put{value: v}, env, k) do
          new_env = Env.put_state(env, @state_key, v)
          k.(:ok, new_env)
        end
      end

      # Install handler:
      comp |> Comp.with_handler(MyEffect, &MyEffect.handle/3)

  ## See Also

  - `Skuld.Comp.IIntercept` - for effects supporting catch clause interception
  - `Skuld.Comp.IInstall` - for effects supporting catch clause handler installation
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
end
