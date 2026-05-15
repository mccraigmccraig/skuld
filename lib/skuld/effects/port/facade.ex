defmodule Skuld.Effects.Port.Facade do
  @moduledoc """
  Generates an effectful dispatch facade for a port contract.

  `use Skuld.Effects.Port.Facade` reads a contract's metadata and generates
  effectful caller functions (returning computations) and `__key__` helpers
  for test stub matching.

  ## Single-module (simplest)

  With no options, the module is both the contract and the dispatch facade:

      defmodule MyApp.Todos do
        use Skuld.Effects.Port.Facade

        defcallback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
        defcallback list_todos() :: [Todo.t()]
      end

  `MyApp.Todos` has effectful `@callback`s, `__callbacks__/0`,
  `__port_effectful__?/0`, and facade dispatch functions — all in one module.

  ## From an existing DoubleDown Contract

  When you have a separate contract module, use the `:double_down_contract`
  option:

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
        use Skuld.Adapter.EffectfulContract,
          double_down_contract: MyApp.Todos.Contract
      end

      defmodule MyApp.Todos do
        use Skuld.Effects.Port.Facade, contract: MyApp.Todos.Effectful
      end

  ## Handler Installation

      comp do
        todo <- MyApp.Todos.get_todo("42")
        todo
      end
      |> Port.with_handler(%{MyApp.Todos => MyApp.Todos.Ecto})
      |> Throw.with_handler()
      |> Comp.run!()

  ## Options

    * `:contract` — the effectful contract module. Defaults to `__MODULE__`.
    * `:double_down_contract` — the DoubleDown contract module. When given (and
      `:contract` is not), implicitly issues
      `use Skuld.Adapter.EffectfulContract` and sets `:contract` to
      `__MODULE__`. Cannot be combined with `:contract`.
    * Without options: single-module pattern — `use DoubleDown.Contract` is
      issued implicitly and everything is generated on the same module.
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
      # Single-module: no options at all — contract defaults to __MODULE__
      # with no separate DD contract. Issue DD.Contract (callbacks: false)
      # and register @before_compile.
      not has_contract? and not has_double_down? ->
        quote do
          use DoubleDown.Contract, callbacks: false

          @skuld_port_contract __MODULE__
          @before_compile {Skuld.Effects.Port.Facade, :__before_compile__}
        end

      # Combined: double_down_contract given, no contract — implicitly issue
      # use EffectfulContract and set contract to __MODULE__
      has_double_down? ->
        quote do
          use Skuld.Adapter.EffectfulContract,
            double_down_contract: unquote(double_down_contract)

          @skuld_port_contract unquote(contract)
          @before_compile {Skuld.Effects.Port.Facade, :__before_compile__}
        end

      # Self-referencing (contract: __MODULE__, no double_down_contract)
      # The effectful contract was already set up (by EffectfulContract above)
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

    {operations, is_single_module?} =
      if contract == env.module do
        double_down_contract = Module.get_attribute(env.module, :skuld_double_down_contract)

        if double_down_contract do
          # Combined pattern: EffectfulContract ran, operations come from
          # the separate DD contract module.
          {double_down_contract.__callbacks__(), false}
        else
          # Single-module pattern: DD.Contract (callbacks: false) ran,
          # __callbacks__/0 exists but can't be called yet. Read raw
          # @callback_operations and normalise to __callbacks__/0 format.
          raw_ops = Module.get_attribute(env.module, :callback_operations) |> Enum.reverse()

          if raw_ops == [] do
            raise CompileError,
              description:
                "#{inspect(env.module)} uses Skuld.Effects.Port.Facade but has no defcallback declarations",
              file: env.file,
              line: 0
          end

          {normalize_operations(raw_ops), true}
        end
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

        {contract.__callbacks__(), false}
      end

    callers = Enum.map(operations, &generate_caller(&1, contract))
    key_helpers = Enum.map(operations, &generate_key_helper(&1, contract))

    # Single-module pattern: generate effectful @callback declarations
    # and __port_effectful__?/0 (DD.Contract already generated __callbacks__/0).
    effectful_block =
      if is_single_module? do
        effectful_callbacks = Enum.map(operations, &generate_effectful_callback/1)

        quote do
          unquote_splicing(effectful_callbacks)

          @doc false
          def __port_effectful__?, do: true
        end
      end

    quote do
      @moduledoc """
      Effectful dispatch facade for `#{inspect(unquote(contract))}`.

      Provides typed public functions returning `computation(return_type)`
      values that dispatch to the configured implementation via the Port
      effect. Also provides `__key__` helpers for test stub matching.
      """

      unquote(effectful_block)
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

  # -------------------------------------------------------------------
  # Raw @callback_operations → __callbacks__/0 format
  # -------------------------------------------------------------------
  #
  # @callback_operations uses :param_names and lacks :arity/:params.
  # __callbacks__/0 uses :params (list) and :arity (integer).
  # Normalise so generate_caller/2 and generate_effectful_callback/1
  # can consume operations from either source.

  defp normalize_operations(raw_ops) do
    Enum.map(raw_ops, fn %{
                           name: name,
                           param_names: param_names,
                           param_types: param_types,
                           return_type: return_type,
                           pre_dispatch: pre_dispatch,
                           warn_on_typespec_mismatch?: warn_on_typespec_mismatch?,
                           user_doc: user_doc
                         } ->
      %{
        name: name,
        params: param_names,
        param_types: param_types,
        return_type: return_type,
        pre_dispatch: pre_dispatch,
        warn_on_typespec_mismatch?: warn_on_typespec_mismatch?,
        user_doc: user_doc,
        arity: length(param_names)
      }
    end)
  end
end
