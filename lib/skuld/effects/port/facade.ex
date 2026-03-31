defmodule Skuld.Effects.Port.Facade do
  @moduledoc """
  Generates an effectful dispatch facade for a `Skuld.Effects.Port.Contract`.

  `use Skuld.Effects.Port.Facade` reads the contract's `__port_operations__/0`
  metadata and generates effectful caller functions (returning computations),
  bang variants (unwrap or throw), and key helpers for test stub matching.

  ## Usage

      defmodule MyApp.Todos.Contract do
        use Skuld.Effects.Port.Contract

        defport get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
        defport list_todos() :: [Todo.t()]
      end

      defmodule MyApp.Todos do
        use Skuld.Effects.Port.Facade, contract: MyApp.Todos.Contract
      end

  This generates effectful caller functions on `MyApp.Todos`:

      # Returns computation({:ok, Todo.t()} | {:error, term()})
      MyApp.Todos.get_todo("42")

      # Bang: unwraps {:ok, v} or dispatches Throw on {:error, r}
      MyApp.Todos.get_todo!("42")

      # Key helper for test stubs
      MyApp.Todos.key(:get_todo, "42")

  ## Handler Installation

      comp do
        todo <- MyApp.Todos.get_todo!("42")
        todo
      end
      |> Port.with_handler(%{MyApp.Todos.Contract => MyApp.Todos.Ecto})
      |> Throw.with_handler()
      |> Comp.run!()

  ## Options

    * `:contract` (required) — the contract module that defines port operations
      via `use Skuld.Effects.Port.Contract` and `defport` declarations.
  """

  @doc false
  defmacro __using__(opts) do
    contract = Keyword.fetch!(opts, :contract)

    quote do
      require unquote(contract)
      @skuld_port_contract unquote(contract)
      @before_compile {Skuld.Effects.Port.Facade, :__before_compile__}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    contract = Module.get_attribute(env.module, :skuld_port_contract)

    unless Code.ensure_loaded?(contract) do
      raise CompileError,
        description:
          "Contract module #{inspect(contract)} is not loaded. " <>
            "Ensure it is compiled before #{inspect(env.module)}.",
        file: env.file,
        line: 0
    end

    unless function_exported?(contract, :__port_operations__, 0) do
      raise CompileError,
        description:
          "#{inspect(contract)} does not define __port_operations__/0. " <>
            "Did you `use Skuld.Effects.Port.Contract` and add `defport` declarations?",
        file: env.file,
        line: 0
    end

    operations = contract.__port_operations__()

    callers = Enum.map(operations, &generate_caller(&1, contract))

    bangs =
      operations
      |> Enum.filter(fn op -> op.bang_mode != :none end)
      |> Enum.map(&generate_bang(&1, contract))

    key_helpers = Enum.map(operations, &generate_key_helper(&1, contract))

    quote do
      @moduledoc """
      Effectful dispatch facade for `#{inspect(unquote(contract))}`.

      Provides typed public functions returning `computation(return_type)`
      values that dispatch to the configured implementation via the Port
      effect. Also provides bang variants (unwrap or throw) and key helpers
      for test stub matching.
      """

      unquote_splicing(callers)
      unquote_splicing(bangs)
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
  # Code Generation: Effectful bang variants
  # -------------------------------------------------------------------

  defp generate_bang(
         %{
           name: name,
           params: param_names,
           param_types: param_types,
           return_type: return_type,
           bang_mode: bang_mode
         },
         contract_module
       ) do
    bang_name = :"#{name}!"
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    args_list = param_vars

    spec_params = param_types

    unwrapped = HexPort.Contract.extract_success_type(return_type)
    comp_type = {:computation, [], [unwrapped]}

    {doc_string, body_ast} =
      case bang_mode do
        :standard ->
          doc =
            "Port operation: `#{bang_name}/#{length(param_names)}`\n\nLike `#{name}/#{length(param_names)}` but unwraps `{:ok, value}` or dispatches `Throw` on error.\n"

          body =
            quote do
              Skuld.Effects.Port.request!(
                unquote(contract_module),
                unquote(name),
                unquote(args_list)
              )
            end

          {doc, body}

        {:custom, unwrap_fn_ast} ->
          doc =
            "Port operation: `#{bang_name}/#{length(param_names)}`\n\nLike `#{name}/#{length(param_names)}` but applies a custom unwrap function, then unwraps `{:ok, value}` or dispatches `Throw` on error.\n"

          body =
            quote do
              Skuld.Effects.Port.request_bang(
                unquote(contract_module),
                unquote(name),
                unquote(args_list),
                unquote(unwrap_fn_ast)
              )
            end

          {doc, body}
      end

    quote do
      @doc unquote(doc_string)
      @spec unquote(bang_name)(unquote_splicing(spec_params)) ::
              Skuld.Comp.Types.unquote(comp_type)
      def unquote(bang_name)(unquote_splicing(param_vars)) do
        unquote(body_ast)
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
      def key(unquote(name), unquote_splicing(param_vars)) do
        Skuld.Effects.Port.key(unquote(contract_module), unquote(name), unquote(args_list))
      end
    end
  end
end
