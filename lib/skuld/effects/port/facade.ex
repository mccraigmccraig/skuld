defmodule Skuld.Effects.Port.Facade do
  @moduledoc """
  Generates an effectful dispatch facade for a port contract.

  `use Skuld.Effects.Port.Facade` reads the contract's `__callbacks__/0`
  metadata and generates effectful caller functions (returning computations),
  bang variants (unwrap or throw), and `__key__` helpers for test stub matching.

  ## Combined effectful contract + facade (simplest)

  When `:double_down_contract` is given (and `:contract` is omitted), the
  effectful contract is set up implicitly and the facade is generated on
  the same module:

      defmodule MyApp.Todos.Contract do
        use DoubleDown.Contract

        defcallback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
        defcallback list_todos() :: [Todo.t()]
      end

      defmodule MyApp.Todos do
        use Skuld.Effects.Port.Facade,
          double_down_contract: MyApp.Todos.Contract
      end

  `MyApp.Todos` is both the effectful contract (has effectful `@callback`s,
  `__callbacks__/0`, `__port_effectful__?/0`) and the dispatch facade.

  ## Separate effectful contract and facade

  For cases where you want them in different modules:

      defmodule MyApp.Todos.Effectful do
        use Skuld.Effects.Port.EffectfulContract,
          double_down_contract: MyApp.Todos.Contract
      end

      defmodule MyApp.Todos do
        use Skuld.Effects.Port.Facade, contract: MyApp.Todos.Effectful
      end

  ## Handler Installation

      comp do
        todo <- MyApp.Todos.get_todo!("42")
        todo
      end
      |> Port.with_handler(%{MyApp.Todos => MyApp.Todos.Ecto})
      |> Throw.with_handler()
      |> Comp.run!()

  ## Options

    * `:contract` — the effectful contract module. Defaults to `__MODULE__`.
    * `:double_down_contract` — the DoubleDown contract module. When given (and
      `:contract` is not), implicitly issues
      `use Skuld.Effects.Port.EffectfulContract` and sets `:contract` to
      `__MODULE__`. Cannot be combined with `:contract`.
  """

  @doc false
  defmacro __using__(opts) do
    has_contract? = Keyword.has_key?(opts, :contract)
    has_double_down? = Keyword.has_key?(opts, :double_down_contract)

    contract =
      case Keyword.get(opts, :contract) do
        nil -> __CALLER__.module
        c -> Macro.expand(c, __CALLER__)
      end

    double_down_contract =
      case Keyword.get(opts, :double_down_contract) do
        nil -> nil
        c -> Macro.expand(c, __CALLER__)
      end

    self_ref? = contract == __CALLER__.module

    # Validate: double_down_contract: is only allowed when contract: is not given
    if has_double_down? and has_contract? do
      raise CompileError,
        description:
          "Cannot specify both :contract and :double_down_contract. " <>
            "Use :double_down_contract for combined effectful contract + facade, " <>
            "or :contract for a separate effectful contract.",
        file: __CALLER__.file,
        line: __CALLER__.line
    end

    cond do
      # Combined: double_down_contract given, no contract — implicitly issue
      # use EffectfulContract and set contract to __MODULE__
      has_double_down? ->
        quote do
          use Skuld.Effects.Port.EffectfulContract,
            double_down_contract: unquote(double_down_contract)

          @skuld_port_contract unquote(contract)
          @before_compile {Skuld.Effects.Port.Facade, :__before_compile__}
        end

      # Self-referencing (contract: __MODULE__ or omitted, no double_down_contract)
      self_ref? ->
        quote do
          @skuld_port_contract unquote(contract)
          @before_compile {Skuld.Effects.Port.Facade, :__before_compile__}
        end

      # Separate module
      true ->
        quote do
          require unquote(contract)
          @skuld_port_contract unquote(contract)
          @before_compile {Skuld.Effects.Port.Facade, :__before_compile__}
        end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    contract = Module.get_attribute(env.module, :skuld_port_contract)

    operations =
      if contract == env.module do
        # Same-module: EffectfulContract's __before_compile__ has already
        # run and defined __callbacks__/0, but we can't call it.
        # Read the double_down_contract (always a separate compiled module)
        # and get operations from there.
        double_down_contract = Module.get_attribute(env.module, :skuld_double_down_contract)

        unless double_down_contract do
          raise CompileError,
            description:
              "#{inspect(contract)} does not have a double_down_contract. " <>
                "Ensure `use Skuld.Effects.Port.EffectfulContract` appears " <>
                "before `use Skuld.Effects.Port.Facade` in the same module.",
            file: env.file,
            line: 0
        end

        double_down_contract.__callbacks__()
      else
        unless Code.ensure_loaded?(contract) do
          raise CompileError,
            description:
              "Contract module #{inspect(contract)} is not loaded. " <>
                "Ensure it is compiled before #{inspect(env.module)}.",
            file: env.file,
            line: 0
        end

        unless function_exported?(contract, :__callbacks__, 0) do
          raise CompileError,
            description:
              "#{inspect(contract)} does not define __callbacks__/0. " <>
                "Did you `use DoubleDown.Contract` and add `defcallback` declarations?",
            file: env.file,
            line: 0
        end

        contract.__callbacks__()
      end

    callers = Enum.map(operations, &generate_caller(&1, contract))

    key_helpers = Enum.map(operations, &generate_key_helper(&1, contract))

    quote do
      @moduledoc """
      Effectful dispatch facade for `#{inspect(unquote(contract))}`.

      Provides typed public functions returning `computation(return_type)`
      values that dispatch to the configured implementation via the Port
      effect. Also provides `__key__` helpers for test stub matching.
      """

      unquote_splicing(callers)
      unquote_splicing(key_helpers)
    end
  end

  # -------------------------------------------------------------------
  # Code Generation: Effectful caller functions
  # -------------------------------------------------------------------

  defp generate_caller(
         %{
           name: name,
           params: param_names,
           param_types: param_types,
           return_type: return_type,
           user_doc: user_doc
         },
         contract_module
       ) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    args_list = param_vars
    spec_params = param_types
    comp_type = {:computation, [], [return_type]}

    doc_ast =
      if user_doc do
        {_line, doc_content} = user_doc

        quote do
          @doc unquote(doc_content)
        end
      else
        doc_string =
          "Port operation: `#{name}/#{length(param_names)}`\n\nDispatches to the configured implementation via the Port effect.\n"

        quote do
          @doc unquote(doc_string)
        end
      end

    quote do
      unquote(doc_ast)
      @spec unquote(name)(unquote_splicing(spec_params)) :: Skuld.Comp.Types.unquote(comp_type)
      def unquote(name)(unquote_splicing(param_vars)) do
        Skuld.Effects.Port.request(unquote(contract_module), unquote(name), unquote(args_list))
      end
    end
  end

  # -------------------------------------------------------------------
  # Code Generation: Key helpers (for Port effect test stubs)
  # -------------------------------------------------------------------

  defp generate_key_helper(%{name: name, params: param_names}, contract_module) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    args_list = param_vars

    doc_string =
      "Build a test stub key for the `#{name}` port operation.\n"

    quote do
      @doc unquote(doc_string)
      def __key__(unquote(name), unquote_splicing(param_vars)) do
        Skuld.Effects.Port.key(unquote(contract_module), unquote(name), unquote(args_list))
      end
    end
  end
end
