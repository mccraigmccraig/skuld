defmodule Skuld.Effects.Port.EffectfulContract do
  @moduledoc """
  Generates an effectful behaviour from a `HexPort.Contract`.

  `use Skuld.Effects.Port.EffectfulContract` reads the operations from a
  plain HexPort contract and generates:

    * Effectful `@callback` declarations with `computation(return_type)`
      return types on the using module
    * `__port_operations__/0` — copied from the HexPort contract
    * `__port_effectful__?/0` — marker for effectful resolver auto-detection

  The effectful contract module *is* the effectful behaviour. Effectful
  implementations declare `@behaviour MyApp.Todos.Effectful`.

  ## Usage

      # Plain contract (HexPort)
      defmodule MyApp.Todos.Contract do
        use HexPort.Contract

        defport get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
      end

      # Effectful contract (Skuld)
      defmodule MyApp.Todos.Effectful do
        use Skuld.Effects.Port.EffectfulContract,
          hex_port_contract: MyApp.Todos.Contract
      end

      # Effectful facade
      defmodule MyApp.Todos do
        use Skuld.Effects.Port.Facade, contract: MyApp.Todos.Effectful
      end

  ## Effectful Implementation

      defmodule MyApp.Todos.EffectfulImpl do
        @behaviour MyApp.Todos.Effectful

        def get_todo(id) do
          Comp.pure({:ok, %Todo{id: id}})
        end
      end

  ## Options

    * `:hex_port_contract` (required) — the HexPort contract module that
      defines `__port_operations__/0` via `use HexPort.Contract`.
  """

  @doc false
  defmacro __using__(opts) do
    hex_port_contract = Keyword.fetch!(opts, :hex_port_contract)

    quote do
      @skuld_hex_port_contract unquote(hex_port_contract)
      @before_compile Skuld.Effects.Port.EffectfulContract
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    hex_port_contract = Module.get_attribute(env.module, :skuld_hex_port_contract)

    unless Code.ensure_loaded?(hex_port_contract) do
      raise CompileError,
        description:
          "HexPort contract module #{inspect(hex_port_contract)} is not loaded. " <>
            "Ensure it is compiled before #{inspect(env.module)}.",
        file: env.file,
        line: 0
    end

    unless function_exported?(hex_port_contract, :__port_operations__, 0) do
      raise CompileError,
        description:
          "#{inspect(hex_port_contract)} does not define __port_operations__/0. " <>
            "Did you `use HexPort.Contract` and add `defport` declarations?",
        file: env.file,
        line: 0
    end

    operations = hex_port_contract.__port_operations__()
    callbacks = Enum.map(operations, &generate_effectful_callback/1)
    escaped_ops = Macro.escape(operations)

    quote do
      unquote_splicing(callbacks)

      @doc false
      def __port_operations__, do: unquote(escaped_ops)

      @doc false
      def __port_effectful__?, do: true
    end
  end

  # -------------------------------------------------------------------
  # Code Generation: Effectful @callback declarations
  # -------------------------------------------------------------------

  defp generate_effectful_callback(%{
         name: name,
         params: param_names,
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
