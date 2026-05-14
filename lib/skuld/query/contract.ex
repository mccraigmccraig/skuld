defmodule Skuld.Query.Contract do
  @moduledoc """
  Macro for defining typed batchable fetch contracts with `deffetch` declarations.

  A Query contract defines a set of fetch operations, generating:

    * **Operation structs** — nested struct modules per fetch (e.g., `MyContract.GetUser`)
    * **Caller functions** — typed public API returning `computation(return_type)`,
      which suspend the current fiber for batched execution
    * **Executor behaviour** — typed callbacks for batch execution, one per fetch
    * **Dispatch function** — `__dispatch__/3` routes from batch key to executor callback
    * **Introspection** — `__query_operations__/0`
  """

  alias Skuld.Comp

  # -------------------------------------------------------------------
  # Bulk Wiring (non-generated, lives on Contract module itself)
  # -------------------------------------------------------------------

  @doc """
  Install multiple contract/executor pairs in one call.

  Accepts either a list of `{contract_module, executor_module}` tuples or a map.

  ## Examples

      comp
      |> Skuld.Query.Contract.with_executors([
        {MyApp.Queries.Users, MyApp.Queries.Users.EctoExecutor},
        {MyApp.Queries.Orders, MyApp.Queries.Orders.EctoExecutor}
      ])

      comp
      |> Skuld.Query.Contract.with_executors(%{
        MyApp.Queries.Users => MyApp.Queries.Users.EctoExecutor,
        MyApp.Queries.Orders => MyApp.Queries.Orders.EctoExecutor
      })
  """
  @spec with_executors(Comp.Types.computation(), [{module(), module()}] | %{module() => module()}) ::
          Comp.Types.computation()
  def with_executors(comp, pairs) when is_map(pairs) do
    with_executors(comp, Map.to_list(pairs))
  end

  def with_executors(comp, pairs) when is_list(pairs) do
    Enum.reduce(pairs, comp, fn {contract, executor}, acc ->
      operations = contract.__query_operations__()

      entries =
        Enum.map(operations, fn %{name: query_name} ->
          {{contract, query_name}, fn ops -> contract.__dispatch__(executor, query_name, ops) end}
        end)

      Skuld.FiberPool.BatchExecutor.with_executors(acc, entries)
    end)
  end

  # -------------------------------------------------------------------
  # __using__ / deffetch / __before_compile__
  # -------------------------------------------------------------------

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Skuld.Query.Contract, only: [deffetch: 1, deffetch: 2]
      Module.register_attribute(__MODULE__, :query_operations, accumulate: true)
      @before_compile Skuld.Query.Contract
    end
  end

  @doc """
  Define a typed fetch operation.

  ## Syntax

      deffetch function_name(param :: type(), ...) :: return_type()
      deffetch function_name(param :: type(), ...) :: return_type(), cache: bool()

  Each `deffetch` declaration generates an operation struct, caller function,
  executor callback, and dispatch clause.
  """
  defmacro deffetch(spec, opts \\ [])

  defmacro deffetch({:"::", _meta, [call_ast, return_type_ast]}, opts) do
    cache_opt = Keyword.get(opts, :cache, true)
    build_deffetch_ast(call_ast, return_type_ast, cache_opt, __CALLER__)
  end

  defmacro deffetch(other, _opts) do
    raise CompileError,
      description:
        "invalid deffetch syntax. Expected: deffetch name(param :: type(), ...) :: return_type()\n" <>
          "Got: #{Macro.to_string(other)}",
      file: __CALLER__.file,
      line: __CALLER__.line
  end

  defp build_deffetch_ast(call_ast, return_type_ast, cache_opt, caller) do
    {name, params} = DoubleDown.Contract.parse_call(call_ast, caller)

    param_names = Enum.map(params, &elem(&1, 0))
    param_types = Enum.map(params, &elem(&1, 1))

    op_base = %{
      name: name,
      param_names: param_names,
      param_types: param_types,
      return_type: return_type_ast,
      cacheable: cache_opt,
      user_doc: nil
    }

    escaped_op = Macro.escape(op_base)

    quote do
      @query_operations (fn ->
                           user_doc = Module.get_attribute(__MODULE__, :doc)
                           op = %{unquote(escaped_op) | user_doc: user_doc}

                           if user_doc, do: Module.delete_attribute(__MODULE__, :doc)

                           op
                         end).()
    end
  end

  # -------------------------------------------------------------------
  # __before_compile__
  # -------------------------------------------------------------------

  @doc false
  defmacro __before_compile__(env) do
    operations = Module.get_attribute(env.module, :query_operations) |> Enum.reverse()

    if operations == [] do
      raise CompileError,
        description:
          "#{inspect(env.module)} uses Query.Contract but has no deffetch declarations",
        file: env.file,
        line: 0
    end

    # Generate all artefacts
    struct_modules = Enum.map(operations, &generate_struct_module(env.module, &1))
    callers = Enum.map(operations, &generate_caller(env.module, &1))
    callbacks = generate_contract_callbacks(env.module, operations)
    dispatch_fns = Enum.map(operations, &generate_dispatch/1)
    introspection = generate_introspection(operations)

    quote do
      # Operation struct modules (must be defined before use in caller bodies)
      (unquote_splicing(struct_modules))

      # Caller functions
      unquote_splicing(callers)

      # Callback declarations
      unquote_splicing(callbacks)

      # Dispatch functions
      unquote_splicing(dispatch_fns)

      # Introspection
      unquote(introspection)
    end
  end

  # -------------------------------------------------------------------
  # Struct Generation (skuld-8fg)
  # -------------------------------------------------------------------

  defp generate_struct_module(contract_module, %{
         name: name,
         param_names: param_names,
         param_types: param_types
       }) do
    struct_module_name = to_pascal_case(name)
    struct_module = Module.concat(contract_module, struct_module_name)

    struct_fields = Enum.map(param_names, fn pname -> {pname, nil} end)

    # Build @type t :: %__MODULE__{field1: type1, field2: type2}
    type_fields =
      Enum.zip(param_names, param_types)
      |> Enum.map(fn {pname, ptype} ->
        {pname, ptype}
      end)

    type_ast =
      if type_fields == [] do
        quote do
          @type t :: %__MODULE__{}
        end
      else
        field_types =
          Enum.map(type_fields, fn {pname, ptype} ->
            {pname, ptype}
          end)

        quote do
          @type t :: %__MODULE__{unquote_splicing(field_types)}
        end
      end

    quote do
      defmodule unquote(struct_module) do
        @moduledoc false
        defstruct unquote(struct_fields)
        unquote(type_ast)
      end
    end
  end

  # -------------------------------------------------------------------
  # Caller Generation (skuld-1x9)
  # -------------------------------------------------------------------

  defp generate_caller(contract_module, %{
         name: name,
         param_names: param_names,
         param_types: param_types,
         return_type: return_type,
         user_doc: user_doc
       }) do
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    spec_params = param_types
    comp_type = {:computation, [], [return_type]}

    struct_module_name = to_pascal_case(name)
    struct_module = Module.concat(contract_module, struct_module_name)

    # Build struct creation: %StructModule{field1: var1, field2: var2}
    struct_fields =
      Enum.zip(param_names, param_vars)
      |> Enum.map(fn {pname, pvar} -> {pname, pvar} end)

    doc_ast =
      if user_doc do
        {_line, doc_content} = user_doc

        quote do
          @doc unquote(doc_content)
        end
      else
        doc_string =
          "Fetch operation: `#{name}/#{length(param_names)}`\n\nSuspends the current fiber for batched execution.\n"

        quote do
          @doc unquote(doc_string)
        end
      end

    quote do
      unquote(doc_ast)
      @spec unquote(name)(unquote_splicing(spec_params)) :: Skuld.Comp.Types.unquote(comp_type)
      def unquote(name)(unquote_splicing(param_vars)) do
        fn env, k ->
          op = %unquote(struct_module){unquote_splicing(struct_fields)}
          batch_key = {unquote(contract_module), unquote(name)}
          resume = fn result, resume_env -> k.(result, resume_env) end
          suspend = Skuld.Comp.InternalSuspend.batch(batch_key, op, make_ref(), resume)
          {suspend, env}
        end
      end
    end
  end

  # -------------------------------------------------------------------
  # Callback Generation (skuld-azy)
  # -------------------------------------------------------------------

  defp generate_contract_callbacks(contract_module, operations) do
    Enum.map(operations, fn %{name: name, return_type: return_type} ->
      struct_module_name = to_pascal_case(name)
      struct_module = Module.concat(contract_module, struct_module_name)

      result_map_type = {:%{}, [], [{{:reference, [], []}, return_type}]}
      comp_type = {:computation, [], [result_map_type]}

      quote do
        @callback unquote(name)(ops :: [{reference(), unquote(struct_module).t()}]) ::
                    Skuld.Comp.Types.unquote(comp_type)
      end
    end)
  end

  # -------------------------------------------------------------------
  # Dispatch Generation (skuld-avo)
  # -------------------------------------------------------------------

  defp generate_dispatch(%{name: name}) do
    quote do
      @doc false
      def __dispatch__(executor_impl, unquote(name), ops) do
        executor_impl.unquote(name)(ops)
      end
    end
  end

  # -------------------------------------------------------------------
  # Introspection (skuld-avo)
  # -------------------------------------------------------------------

  defp generate_introspection(operations) do
    op_maps =
      Enum.map(operations, fn %{
                                name: name,
                                param_names: param_names,
                                param_types: param_types,
                                return_type: return_type,
                                cacheable: cacheable
                              } ->
        quote do
          %{
            name: unquote(name),
            params: unquote(param_names),
            param_types: unquote(Macro.escape(param_types)),
            return_type: unquote(Macro.escape(return_type)),
            arity: unquote(length(param_names)),
            cacheable: unquote(cacheable)
          }
        end
      end)

    quote do
      @doc false
      def __query_operations__ do
        unquote(op_maps)
      end
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  # Convert snake_case atom to PascalCase atom.
  # e.g., :get_user -> :GetUser, :get_users_by_org -> :GetUsersByOrg
  @doc false
  def to_pascal_case(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(&String.capitalize/1)
    |> String.to_atom()
  end
end
