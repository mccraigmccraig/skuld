defmodule Skuld.Effects.Port.Contract do
  @moduledoc """
  Macro for defining typed port contracts with `defport` declarations.

  A Port contract defines a set of operations, generating:

    * **Consumer behaviour** (`__MODULE__.Consumer`) — plain Elixir callbacks for
      non-effectful implementations
    * **Provider behaviour** (`__MODULE__.Provider`) — computation-returning callbacks
      for effectful implementations
    * **Caller functions** — typed public API returning `computation(return_type)`,
      which also satisfy the Provider behaviour
    * **Bang variants** — unwrap `{:ok, v}` or dispatch Throw (when applicable)
    * **Key helpers** — for test stub matching
    * **Introspection** — `__port_operations__/0`

  ## Consumer vs Provider

  The contract generates two behaviour modules:

    * `MyContract.Consumer` — callbacks return plain values. Use for non-effectful
      implementations that are called via `Port.with_handler/2`.
    * `MyContract.Provider` — callbacks return `computation(return_type)`. Use for
      effectful implementations that need to be wrapped with `Port.Provider`.

  The contract module's own caller functions satisfy the Provider behaviour (they
  return computations that emit Port effects).

  ## Bang Variant Generation

  Bang variants (`name!`) are generated based on the return type:

    * **Auto-detect** (default): If the return type contains `{:ok, T}`, a bang
      variant is generated that unwraps `{:ok, value}` or dispatches `Throw` on
      `{:error, reason}`. If no `{:ok, T}` is found, no bang is generated.
    * **`bang: true`**: Force bang generation with standard `{:ok, v}` / `{:error, r}`
      unwrapping, even if the return type doesn't match the pattern.
    * **`bang: false`**: Suppress bang generation even if the return type matches.
    * **`bang: unwrap_fn`**: Generate a bang that first applies `unwrap_fn` to the
      raw result (which must return `{:ok, v}` or `{:error, r}`), then unwraps.

  ## Example

      defmodule MyApp.Repository do
        use Skuld.Effects.Port.Contract

        # Auto-detected: has {:ok, T}, bang generated automatically
        defport get_todo(tenant_id :: String.t(), id :: String.t()) ::
                  {:ok, Todo.t()} | {:error, term()}

        # No {:ok, T} in return type, no bang generated
        defport find_user(id :: String.t()) :: User.t() | nil

        # Force bang with custom unwrap (nil → error, value → ok)
        defport find_user(id :: String.t()) :: User.t() | nil,
          bang: fn
            nil -> {:error, :not_found}
            user -> {:ok, user}
          end

        # Suppress bang even though return type has {:ok, T}
        defport raw_query(sql :: String.t()) ::
                  {:ok, term()} | {:error, term()},
                  bang: false
      end

  This generates:

      # Consumer behaviour (plain Elixir)
      MyApp.Repository.Consumer
      @callback get_todo(String.t(), String.t()) :: {:ok, Todo.t()} | {:error, term()}

      # Provider behaviour (computation-returning)
      MyApp.Repository.Provider
      @callback get_todo(String.t(), String.t()) :: computation({:ok, Todo.t()} | {:error, term()})

      # Caller (returns computation, satisfies Provider behaviour)
      @spec get_todo(String.t(), String.t()) :: Types.computation({:ok, Todo.t()} | {:error, term()})
      def get_todo(tenant_id, id)

      # Bang (unwraps or throws) — auto-detected from {:ok, T}
      @spec get_todo!(String.t(), String.t()) :: Types.computation(Todo.t())
      def get_todo!(tenant_id, id)

      # Key helper (for test stubs)
      def key(:get_todo, tenant_id, id)

  ## Consumer Implementation

      defmodule MyApp.Repository.Ecto do
        @behaviour MyApp.Repository.Consumer

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
      import Skuld.Effects.Port.Contract, only: [defport: 1, defport: 2]
      Module.register_attribute(__MODULE__, :port_operations, accumulate: true)
      @before_compile Skuld.Effects.Port.Contract
    end
  end

  @doc """
  Define a typed port operation.

  ## Syntax

      defport function_name(param :: type(), ...) :: return_type()
      defport function_name(param :: type(), ...) :: return_type(), bang: option

  Each `defport` declaration generates a caller function, `@callback`, key
  helper, and `@doc` strings. A bang variant is generated based on the `bang`
  option:

    * **omitted** — auto-detect: generate bang only if return type contains `{:ok, T}`
    * **`true`** — force standard `{:ok, v}` / `{:error, r}` unwrapping
    * **`false`** — suppress bang generation
    * **`unwrap_fn`** — generate bang using custom unwrap function, which receives
      the raw result and must return `{:ok, v}` or `{:error, r}`

  Default arguments (`\\\\`) are not supported — use a wrapper function instead.
  """
  defmacro defport(spec, opts \\ [])

  defmacro defport({:"::", _meta, [call_ast, return_type_ast]}, opts) do
    bang_opt = Keyword.get(opts, :bang, :auto)
    build_defport_ast(call_ast, return_type_ast, bang_opt)
  end

  defmacro defport(other, _opts) do
    raise CompileError,
      description:
        "invalid defport syntax. Expected: defport name(param :: type(), ...) :: return_type()\n" <>
          "Got: #{Macro.to_string(other)}",
      file: __CALLER__.file,
      line: __CALLER__.line
  end

  defp build_defport_ast(call_ast, return_type_ast, bang_opt) do
    {name, params} = parse_call(call_ast)

    param_names = Enum.map(params, &elem(&1, 0))
    param_types = Enum.map(params, &elem(&1, 1))

    # Determine bang mode:
    #   :auto — generate if return type has {:ok, T}, with standard unwrap
    #   true — force standard unwrap
    #   false — no bang
    #   ast — custom unwrap function (any non-boolean, non-:auto expression)
    bang_mode =
      case bang_opt do
        :auto ->
          if has_ok_error_pattern?(return_type_ast), do: :standard, else: :none

        true ->
          :standard

        false ->
          :none

        custom_fn_ast ->
          {:custom, custom_fn_ast}
      end

    # Build the base operation map (without user_doc — that's captured at module level)
    op_base = %{
      name: name,
      param_names: param_names,
      param_types: param_types,
      return_type: return_type_ast,
      bang_mode: bang_mode,
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

  @doc false
  defmacro __before_compile__(env) do
    operations = Module.get_attribute(env.module, :port_operations) |> Enum.reverse()

    if operations == [] do
      raise CompileError,
        description: "#{inspect(env.module)} uses Port.Contract but has no defport declarations",
        file: env.file,
        line: 0
    end

    consumer_module = Module.concat(env.module, Consumer)
    provider_module = Module.concat(env.module, Provider)

    consumer_callbacks = Enum.map(operations, &generate_callback/1)
    provider_callbacks = Enum.map(operations, &generate_provider_callback/1)

    callers = Enum.map(operations, &generate_caller/1)

    bangs =
      operations
      |> Enum.filter(fn op -> op.bang_mode != :none end)
      |> Enum.map(&generate_bang/1)

    key_helpers = Enum.map(operations, &generate_key_helper/1)
    introspection = generate_introspection(operations)

    quote do
      defmodule unquote(consumer_module) do
        @moduledoc """
        Consumer behaviour for `#{inspect(unquote(env.module))}`.

        Defines plain Elixir callbacks — implementations receive and return
        ordinary values (no computations). Use this behaviour for modules that
        provide non-effectful implementations of the port contract.
        """

        unquote_splicing(consumer_callbacks)
      end

      defmodule unquote(provider_module) do
        @moduledoc """
        Provider behaviour for `#{inspect(unquote(env.module))}`.

        Defines computation-returning callbacks — implementations return
        `computation(return_type)` values. Use this behaviour for modules that
        provide effectful implementations of the port contract.

        The contract module's own caller functions satisfy this behaviour.
        """

        unquote_splicing(provider_callbacks)
      end

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

  defp generate_provider_callback(%{
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

    # Provider callbacks return computation(return_type) instead of plain return_type
    comp_type = {:computation, [], [return_type]}

    quote do
      @callback unquote(name)(unquote_splicing(callback_params)) ::
                  Skuld.Comp.Types.unquote(comp_type)
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
         return_type: return_type,
         bang_mode: bang_mode
       }) do
    bang_name = :"#{name}!"
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    args_list = param_vars

    spec_params = param_types

    # Extract unwrapped success type for bang spec
    unwrapped = extract_success_type(return_type)
    comp_type = {:computation, [], [unwrapped]}

    {doc_string, body_ast} =
      case bang_mode do
        :standard ->
          doc =
            "Port operation: `#{bang_name}/#{length(param_names)}`\n\nLike `#{name}/#{length(param_names)}` but unwraps `{:ok, value}` or dispatches `Throw` on error.\n"

          body =
            quote do
              Skuld.Effects.Port.request!(__MODULE__, unquote(name), unquote(args_list))
            end

          {doc, body}

        {:custom, unwrap_fn_ast} ->
          doc =
            "Port operation: `#{bang_name}/#{length(param_names)}`\n\nLike `#{name}/#{length(param_names)}` but applies a custom unwrap function, then unwraps `{:ok, value}` or dispatches `Throw` on error.\n"

          body =
            quote do
              Skuld.Effects.Port.request_bang(
                __MODULE__,
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

  # Check whether the return type AST contains an {:ok, T} pattern.
  @doc false
  def has_ok_error_pattern?(return_type_ast) do
    extract_from_union(return_type_ast) != nil
  end

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

  # Elixir AST represents 2-tuples as {left, right} directly.
  # Note: function calls like ok(arg) are 3-tuples {:ok, meta, args}, not 2-tuples,
  # so this only matches actual 2-tuple type literals like {:ok, some_type}.
  defp extract_from_ok_tuple({:ok, inner_type}), do: inner_type

  defp extract_from_ok_tuple(_), do: nil
end
