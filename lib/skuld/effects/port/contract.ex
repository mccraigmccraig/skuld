defmodule Skuld.Effects.Port.Contract do
  @moduledoc """
  Macro for defining typed port contracts with `defport` declarations.

  A Port contract defines a set of operations as a behaviour, generating:

    * **Caller functions** — typed public API returning `computation(return_type)`
    * **Bang variants** — unwrap `{:ok, v}` or dispatch Throw
    * **Behaviour callbacks** — typed `@callback` for implementations
    * **Key helpers** — for test stub matching
    * **Introspection** — `__port_operations__/0`

  ## Example

      defmodule MyApp.Repository do
        use Skuld.Effects.Port.Contract

        defport get_todo(tenant_id :: String.t(), id :: String.t()) ::
                  {:ok, Todo.t()} | {:error, term()}

        defport list_todos(tenant_id :: String.t()) ::
                  {:ok, [Todo.t()]} | {:error, term()}
      end

  This generates:

      # Caller (returns computation)
      @spec get_todo(String.t(), String.t()) :: Types.computation({:ok, Todo.t()} | {:error, term()})
      def get_todo(tenant_id, id)

      # Bang (unwraps or throws)
      @spec get_todo!(String.t(), String.t()) :: Types.computation(Todo.t())
      def get_todo!(tenant_id, id)

      # Callback (for implementations)
      @callback get_todo(String.t(), String.t()) :: {:ok, Todo.t()} | {:error, term()}

      # Key helper (for test stubs)
      def key(:get_todo, tenant_id, id)

  ## Implementation

      defmodule MyApp.Repository.Ecto do
        @behaviour MyApp.Repository

        @impl true
        def get_todo(tenant_id, id), do: ...
      end

  ## Handler Installation

      my_comp
      |> Port.with_handler(%{MyApp.Repository => MyApp.Repository.Ecto})
      |> Comp.run!()
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Skuld.Effects.Port.Contract, only: [defport: 1]
      Module.register_attribute(__MODULE__, :port_operations, accumulate: true)
      @before_compile Skuld.Effects.Port.Contract
    end
  end

  @doc """
  Define a typed port operation.

  ## Syntax

      defport function_name(param :: type(), ...) :: return_type()

  Each `defport` declaration generates a caller function, bang variant,
  `@callback`, key helper, and `@doc` strings.

  Default arguments (`\\\\`) are not supported in v1 — use a wrapper function instead.
  """
  defmacro defport({:"::", _meta, [call_ast, return_type_ast]}) do
    {name, params} = parse_call(call_ast)

    param_names = Enum.map(params, &elem(&1, 0))
    param_types = Enum.map(params, &elem(&1, 1))

    # Build the base operation map (without user_doc — that's captured at module level)
    op_base = %{
      name: name,
      param_names: param_names,
      param_types: param_types,
      return_type: return_type_ast,
      user_doc: nil
    }

    escaped_op = Macro.escape(op_base)

    # Capture @doc at module compilation time (not macro expansion time)
    # and merge it into the operation before storing
    quote do
      @port_operations (fn ->
                          user_doc = Module.get_attribute(__MODULE__, :doc)
                          op = %{unquote(escaped_op) | user_doc: user_doc}

                          # Clear @doc so it doesn't leak to the next definition
                          if user_doc, do: Module.delete_attribute(__MODULE__, :doc)

                          op
                        end).()
    end
  end

  defmacro defport(other) do
    raise CompileError,
      description:
        "invalid defport syntax. Expected: defport name(param :: type(), ...) :: return_type()\n" <>
          "Got: #{Macro.to_string(other)}",
      file: __CALLER__.file,
      line: __CALLER__.line
  end

  @doc false
  defmacro __before_compile__(env) do
    operations = Module.get_attribute(env.module, :port_operations) |> Enum.reverse()

    if operations == [] do
      raise CompileError,
        description: "#{inspect(env.module)} uses Port.Contract but has no defport declarations",
        file: env.file,
        line: 0
    end

    callbacks = Enum.map(operations, &generate_callback/1)
    callers = Enum.map(operations, &generate_caller/1)
    bangs = Enum.map(operations, &generate_bang/1)
    key_helpers = Enum.map(operations, &generate_key_helper/1)
    introspection = generate_introspection(operations)

    quote do
      unquote_splicing(callbacks)
      unquote_splicing(callers)
      unquote_splicing(bangs)
      unquote_splicing(key_helpers)
      unquote(introspection)
    end
  end

  # -------------------------------------------------------------------
  # AST Parsing
  # -------------------------------------------------------------------

  # Parse `name(param1 :: type1, param2 :: type2, ...)`
  # Returns {name, [{param_name, type_ast}, ...]}
  @doc false
  def parse_call({name, _meta, nil}) when is_atom(name) do
    # Zero-arg: defport health_check() :: :ok
    {name, []}
  end

  def parse_call({name, _meta, args}) when is_atom(name) and is_list(args) do
    params =
      Enum.map(args, fn
        {:"::", _, [{param_name, _, _}, type_ast]} when is_atom(param_name) ->
          {param_name, type_ast}

        {:\\, _, _} ->
          raise CompileError,
            description:
              "defport does not support default arguments (\\\\). " <>
                "Use a wrapper function instead.\n" <>
                "  defport #{name}(...) :: ...\n" <>
                "  def #{name}_default(...), do: #{name}(..., default_value)",
            file: "",
            line: 0

        other ->
          raise CompileError,
            description:
              "defport parameters must be typed: `name :: type()`. Got: #{Macro.to_string(other)}",
            file: "",
            line: 0
      end)

    {name, params}
  end

  def parse_call(other) do
    raise CompileError,
      description: "invalid defport call syntax. Got: #{Macro.to_string(other)}",
      file: "",
      line: 0
  end

  # -------------------------------------------------------------------
  # Code Generation
  # -------------------------------------------------------------------

  defp generate_callback(%{
         name: name,
         param_names: param_names,
         param_types: param_types,
         return_type: return_type
       }) do
    # Build typed callback params: param_name :: type
    callback_params =
      Enum.zip(param_names, param_types)
      |> Enum.map(fn {pname, ptype} ->
        {:"::", [], [{pname, [], nil}, ptype]}
      end)

    quote do
      @callback unquote(name)(unquote_splicing(callback_params)) :: unquote(return_type)
    end
  end

  defp generate_caller(%{
         name: name,
         param_names: param_names,
         param_types: param_types,
         return_type: return_type,
         user_doc: user_doc
       }) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    args_list = param_vars

    # Build @spec param types
    spec_params = param_types

    # Phantom type: computation(return_type)
    comp_type = {:computation, [], [return_type]}

    doc_ast =
      if user_doc do
        # User provided their own @doc — restore it
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
        Skuld.Effects.Port.request(__MODULE__, unquote(name), unquote(args_list))
      end
    end
  end

  defp generate_bang(%{
         name: name,
         param_names: param_names,
         param_types: param_types,
         return_type: return_type
       }) do
    bang_name = :"#{name}!"
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    args_list = param_vars

    spec_params = param_types

    # Extract unwrapped success type for bang spec
    unwrapped = extract_success_type(return_type)
    comp_type = {:computation, [], [unwrapped]}

    doc_string =
      "Port operation: `#{bang_name}/#{length(param_names)}`\n\nLike `#{name}/#{length(param_names)}` but unwraps `{:ok, value}` or dispatches `Throw` on error.\n"

    quote do
      @doc unquote(doc_string)
      @spec unquote(bang_name)(unquote_splicing(spec_params)) ::
              Skuld.Comp.Types.unquote(comp_type)
      def unquote(bang_name)(unquote_splicing(param_vars)) do
        Skuld.Effects.Port.request!(__MODULE__, unquote(name), unquote(args_list))
      end
    end
  end

  defp generate_key_helper(%{name: name, param_names: param_names}) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    args_list = param_vars

    doc_string =
      if param_names != [] do
        param_example = param_names |> Enum.map_join(", ", &to_string/1)

        "Build a test stub key for the `#{name}` port operation.\n\nUse with `Port.with_test_handler/2`:\n\n    Port.with_test_handler(%{\n      __MODULE__.key(:#{name}, #{param_example}) => {:ok, result}\n    })\n"
      else
        "Build a test stub key for the `#{name}` port operation.\n\nUse with `Port.with_test_handler/2`:\n\n    Port.with_test_handler(%{\n      __MODULE__.key(:#{name}) => {:ok, result}\n    })\n"
      end

    quote do
      @doc unquote(doc_string)
      def key(unquote(name), unquote_splicing(param_vars)) do
        Skuld.Effects.Port.key(__MODULE__, unquote(name), unquote(args_list))
      end
    end
  end

  defp generate_introspection(operations) do
    op_maps =
      Enum.map(operations, fn %{
                                name: name,
                                param_names: param_names,
                                param_types: param_types,
                                return_type: return_type
                              } ->
        quote do
          %{
            name: unquote(name),
            params: unquote(param_names),
            param_types: unquote(Macro.escape(param_types)),
            return_type: unquote(Macro.escape(return_type)),
            arity: unquote(length(param_names))
          }
        end
      end)

    quote do
      @doc false
      def __port_operations__ do
        unquote(op_maps)
      end
    end
  end

  # -------------------------------------------------------------------
  # Type Extraction
  # -------------------------------------------------------------------

  # Extract the success type from {:ok, T} | {:error, _} patterns.
  # Falls back to term() if the pattern doesn't match.
  @doc false
  def extract_success_type(return_type_ast) do
    case extract_from_union(return_type_ast) do
      nil -> {:term, [], []}
      type -> type
    end
  end

  # Walk a union type looking for {:ok, T}
  defp extract_from_union({:|, _, [left, right]}) do
    extract_from_ok_tuple(left) || extract_from_union(right)
  end

  defp extract_from_union(type) do
    extract_from_ok_tuple(type)
  end

  # Match {:ok, T} in AST form
  # Two-element tuple: {:{}, _, [:ok, inner_type]} or {:ok, inner_type} (2-tuple shorthand)
  defp extract_from_ok_tuple({:{}, _, [:ok, inner_type]}), do: inner_type

  # Elixir AST represents 2-tuples as {left, right} directly
  defp extract_from_ok_tuple({:ok, inner_type}) when not is_list(inner_type), do: inner_type

  defp extract_from_ok_tuple(_), do: nil
end
