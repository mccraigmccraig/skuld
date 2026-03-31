defmodule Skuld.Effects.Port.Contract do
  @moduledoc """
  Macro for defining typed port contracts with `defport` declarations.

  Builds on `HexPort.Contract` to generate the plain behaviour,
  then adds Skuld-specific effectful layers on top.

  `use Skuld.Effects.Port.Contract` generates:

    * `@callback` declarations on the contract module itself — the
      contract module *is* the plain behaviour (from HexPort)
    * `__port_operations__/0` — introspection metadata (from HexPort)
    * `X.Effectful` — computation-returning callbacks for effectful
      implementations (from Skuld)

  To generate an effectful dispatch facade, use
  `Skuld.Effects.Port.Facade` in a separate module:

      defmodule MyApp.Todos.Contract do
        use Skuld.Effects.Port.Contract

        defport get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
      end

      defmodule MyApp.Todos do
        use Skuld.Effects.Port.Facade, contract: MyApp.Todos.Contract
      end

  ## Plain vs Effectful Behaviour

  The contract module *is* the plain behaviour (via HexPort). It also
  generates an `X.Effectful` submodule:

    * `MyContract` (plain) — callbacks return plain values. Use for
      non-effectful implementations called via `Port.with_handler/2`.
    * `MyContract.Effectful` — callbacks return `computation(return_type)`.
      Use for effectful implementations.

  ## Plain Implementation

      defmodule MyApp.Todos.Ecto do
        @behaviour MyApp.Todos.Contract
        @impl true
        def get_todo(id), do: ...
      end

  ## Handler Installation

      MyApp.Todos.get_todo!("42")
      |> Port.with_handler(%{MyApp.Todos.Contract => MyApp.Todos.Ecto})
      |> Throw.with_handler()
      |> Comp.run!()
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      # HexPort.Contract generates X.Behaviour and __port_operations__/0
      use HexPort.Contract
      # Skuld adds effectful layers after HexPort's __before_compile__ runs
      @before_compile Skuld.Effects.Port.Contract
    end
  end

  # defport macro is provided by HexPort.Contract via `use HexPort.Contract`

  @doc false
  defmacro __before_compile__(env) do
    # __port_operations__/0 is already defined by HexPort.Contract's __before_compile__
    # which ran before this one (registered first via `use HexPort.Contract`).
    operations = Module.get_attribute(env.module, :port_operations) |> Enum.reverse()

    provider_module = Module.concat(env.module, Effectful)

    provider_callbacks = Enum.map(operations, &generate_provider_callback/1)

    quote do
      defmodule unquote(provider_module) do
        @moduledoc """
        Effectful behaviour for `#{inspect(unquote(env.module))}`.

        Defines computation-returning callbacks — implementations return
        `computation(return_type)` values. Implementations satisfying this
        behaviour can be used with `Port.with_handler/2` and are
        auto-detected as effectful resolvers.

        Use `use #{inspect(unquote(provider_module))}` (preferred) or
        `@behaviour #{inspect(unquote(provider_module))}` plus a manual
        `def __port_effectful__?, do: true` marker.
        """

        defmacro __using__(_opts) do
          behaviour_mod = unquote(provider_module)

          quote do
            @behaviour unquote(behaviour_mod)
            def __port_effectful__?, do: true
          end
        end

        unquote_splicing(provider_callbacks)
      end
    end
  end

  # -------------------------------------------------------------------
  # Code Generation: Effectful behaviour callbacks
  # -------------------------------------------------------------------

  defp generate_provider_callback(%{
         name: name,
         param_names: param_names,
         param_types: param_types,
         return_type: return_type
       }) do
    callback_params =
      Enum.zip(param_names, param_types)
      |> Enum.map(fn {pname, ptype} ->
        {:"::", [], [{pname, [], nil}, ptype]}
      end)

    comp_type = {:computation, [], [return_type]}

    quote do
      @callback unquote(name)(unquote_splicing(callback_params)) ::
                  Skuld.Comp.Types.unquote(comp_type)
    end
  end
end
