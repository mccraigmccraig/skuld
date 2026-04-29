defmodule Skuld.Effects.Port.EffectfulContract do
  @moduledoc """
  Generates an effectful behaviour from a `DoubleDown.Contract`.

  `use Skuld.Effects.Port.EffectfulContract` reads the operations from a
  plain DoubleDown contract and generates:

    * Effectful `@callback` declarations with `computation(return_type)`
      return types on the using module
    * `__callbacks__/0` — copied from the DoubleDown contract
    * `__port_effectful__?/0` — marker for effectful resolver auto-detection

  The effectful contract module *is* the effectful behaviour. Effectful
  implementations declare `@behaviour MyApp.Todos.Effectful`.

  ## Usage

      # Plain contract (DoubleDown)
      defmodule MyApp.Todos.Contract do
        use DoubleDown.Contract

        defcallback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
      end

      # Effectful contract (Skuld)
      defmodule MyApp.Todos.Effectful do
        use Skuld.Effects.Port.EffectfulContract,
          double_down_contract: MyApp.Todos.Contract
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

    * `:double_down_contract` (required) — the DoubleDown contract module that
      defines `__callbacks__/0` via `use DoubleDown.Contract`.
  """

  @doc false
  defmacro __using__(opts) do
    double_down_contract = Keyword.fetch!(opts, :double_down_contract)

    quote do
      @skuld_double_down_contract unquote(double_down_contract)
      @before_compile Skuld.Effects.Port.EffectfulContract
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    double_down_contract = Module.get_attribute(env.module, :skuld_double_down_contract)

    unless Code.ensure_loaded?(double_down_contract) do
      raise CompileError,
        description:
          "DoubleDown contract module #{inspect(double_down_contract)} is not loaded. " <>
            "Ensure it is compiled before #{inspect(env.module)}.",
        file: env.file,
        line: 0
    end

    unless function_exported?(double_down_contract, :__callbacks__, 0) do
      raise CompileError,
        description:
          "#{inspect(double_down_contract)} does not define __callbacks__/0. " <>
            "Did you `use DoubleDown.Contract` and add `defcallback` declarations?",
        file: env.file,
        line: 0
    end

    operations = double_down_contract.__callbacks__()
    callbacks = Enum.map(operations, &generate_effectful_callback/1)
    escaped_ops = Macro.escape(operations)

    quote do
      unquote_splicing(callbacks)

      @doc false
      def __callbacks__, do: unquote(escaped_ops)

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
