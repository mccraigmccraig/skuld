defmodule Skuld.Query.Contract do
  @moduledoc """
  Macro for defining typed batchable fetch contracts with `deffetch` declarations.

  A Query contract defines a set of fetch operations, generating:

    * **Operation structs** — nested struct modules per fetch (e.g., `MyContract.GetUser`)
    * **Caller functions** — typed public API returning `computation(return_type)`,
      which suspend the current fiber for batched execution
    * **Executor behaviour** (`__MODULE__.Executor`) — typed callbacks for batch
      execution, one per fetch
    * **Dispatch function** — `__dispatch__/3` routes from batch key to executor callback
    * **Wiring function** — `with_executor/2` installs an executor module for all fetches
    * **Bang variants** — unwrap `{:ok, v}` or dispatch Throw (when applicable)
    * **Introspection** — `__query_operations__/0`

  ## Example

      defmodule MyApp.Queries.Users do
        use Skuld.Query.Contract

        deffetch get_user(id :: String.t()) :: User.t() | nil
        deffetch get_users_by_org(org_id :: String.t()) :: [User.t()]
        deffetch get_user_count(org_id :: String.t()) :: non_neg_integer()
      end

  This generates:

      # Operation struct
      MyApp.Queries.Users.GetUser   # defstruct [:id]
      MyApp.Queries.Users.GetUsersByOrg   # defstruct [:org_id]

      # Executor behaviour
      MyApp.Queries.Users.Executor
      @callback get_user(ops :: [{reference(), GetUser.t()}]) :: computation(...)

      # Caller (suspends fiber for batching)
      @spec get_user(String.t()) :: Types.computation(User.t() | nil)
      def get_user(id)

      # Wiring
      @spec with_executor(computation(), module()) :: computation()
      def with_executor(comp, executor_module)

  ## Executor Implementation

      defmodule MyApp.Queries.Users.EctoExecutor do
        @behaviour MyApp.Queries.Users.Executor

        @impl true
        def get_user(ops) do
          ids = Enum.map(ops, fn {_ref, %GetUser{id: id}} -> id end) |> Enum.uniq()
          Comp.bind(Reader.ask(:repo), fn repo ->
            results = repo.all(User, ids)
            by_id = Map.new(results, &{&1.id, &1})
            Comp.pure(Map.new(ops, fn {ref, %GetUser{id: id}} -> {ref, Map.get(by_id, id)} end))
          end)
        end
      end

  ## Wiring

      my_comp
      |> MyApp.Queries.Users.with_executor(MyApp.Queries.Users.EctoExecutor)
      |> FiberPool.with_handler()
      |> Comp.run()

  ## Bulk Wiring

      my_comp
      |> Skuld.Query.Contract.with_executors([
        {MyApp.Queries.Users, MyApp.Queries.Users.EctoExecutor},
        {MyApp.Queries.Orders, MyApp.Queries.Orders.EctoExecutor}
      ])

  ## Bang Variant Generation

  Same rules as `Port.Contract`:

    * **Auto-detect** (default): If the return type contains `{:ok, T}`, a bang
      variant is generated that unwraps `{:ok, value}` or dispatches `Throw` on
      `{:error, reason}`.
    * **`bang: true`**: Force standard unwrapping.
    * **`bang: false`**: Suppress bang generation.
    * **`bang: unwrap_fn`**: Custom unwrap function.
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
      contract.with_executor(acc, executor)
    end)
  end

  # -------------------------------------------------------------------
  # __using__ / deffetch / __before_compile__
  # -------------------------------------------------------------------

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Skuld.Query.Contract, only: [deffetch: 1, deffetch: 2, defquery: 1, defquery: 2]
      Module.register_attribute(__MODULE__, :query_operations, accumulate: true)
      @before_compile Skuld.Query.Contract
    end
  end

  @doc """
  Define a typed fetch operation.

  ## Syntax

      deffetch function_name(param :: type(), ...) :: return_type()
      deffetch function_name(param :: type(), ...) :: return_type(), bang: option

  Each `deffetch` declaration generates an operation struct, caller function,
  executor callback, dispatch clause, and optionally a bang variant.

  The `bang` option follows the same rules as `Port.Contract.defport`:

    * **omitted** -- auto-detect: generate bang only if return type contains `{:ok, T}`
    * **`true`** -- force standard `{:ok, v}` / `{:error, r}` unwrapping
    * **`false`** -- suppress bang generation
    * **`unwrap_fn`** -- custom unwrap function
  """
  defmacro deffetch(spec, opts \\ [])

  defmacro deffetch({:"::", _meta, [call_ast, return_type_ast]}, opts) do
    bang_opt = Keyword.get(opts, :bang, :auto)
    cache_opt = Keyword.get(opts, :cache, true)
    build_deffetch_ast(call_ast, return_type_ast, bang_opt, cache_opt, __CALLER__)
  end

  defmacro deffetch(other, _opts) do
    raise CompileError,
      description:
        "invalid deffetch syntax. Expected: deffetch name(param :: type(), ...) :: return_type()\n" <>
          "Got: #{Macro.to_string(other)}",
      file: __CALLER__.file,
      line: __CALLER__.line
  end

  @doc """
  Deprecated: use `deffetch` instead.

  `defquery` is a deprecated alias for `deffetch`. It will be removed in a future release.
  """
  defmacro defquery(spec, opts \\ [])

  defmacro defquery({:"::", _meta, [call_ast, return_type_ast]}, opts) do
    IO.warn("defquery is deprecated, use deffetch instead", __CALLER__)
    bang_opt = Keyword.get(opts, :bang, :auto)
    cache_opt = Keyword.get(opts, :cache, true)
    build_deffetch_ast(call_ast, return_type_ast, bang_opt, cache_opt, __CALLER__)
  end

  defmacro defquery(other, _opts) do
    raise CompileError,
      description:
        "invalid defquery syntax. Expected: deffetch name(param :: type(), ...) :: return_type()\n" <>
          "Got: #{Macro.to_string(other)}",
      file: __CALLER__.file,
      line: __CALLER__.line
  end

  defp build_deffetch_ast(call_ast, return_type_ast, bang_opt, cache_opt, caller) do
    {name, params} = Skuld.Effects.Port.Contract.parse_call(call_ast, caller)

    param_names = Enum.map(params, &elem(&1, 0))
    param_types = Enum.map(params, &elem(&1, 1))

    bang_mode =
      case bang_opt do
        :auto ->
          if Skuld.Effects.Port.Contract.has_ok_error_pattern?(return_type_ast),
            do: :standard,
            else: :none

        true ->
          :standard

        false ->
          :none

        custom_fn_ast ->
          {:custom, custom_fn_ast}
      end

    op_base = %{
      name: name,
      param_names: param_names,
      param_types: param_types,
      return_type: return_type_ast,
      bang_mode: bang_mode,
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

    bangs =
      operations
      |> Enum.filter(fn op -> op.bang_mode != :none end)
      |> Enum.map(&generate_bang(env.module, &1))

    executor_module = generate_executor_module(env.module, operations)
    dispatch_fns = Enum.map(operations, &generate_dispatch/1)
    with_executor_fn = generate_with_executor(operations)
    introspection = generate_introspection(operations)

    quote do
      # Operation struct modules (must be defined before use in caller bodies)
      (unquote_splicing(struct_modules))

      # Executor behaviour module
      unquote(executor_module)

      # Caller functions
      unquote_splicing(callers)

      # Bang variants
      unquote_splicing(bangs)

      # Dispatch functions
      unquote_splicing(dispatch_fns)

      # with_executor/2
      unquote(with_executor_fn)

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
  # Executor Behaviour Generation (skuld-azy)
  # -------------------------------------------------------------------

  defp generate_executor_module(contract_module, operations) do
    executor_module = Module.concat(contract_module, Executor)

    callbacks =
      Enum.map(operations, fn %{name: name, param_names: _param_names, return_type: return_type} ->
        struct_module_name = to_pascal_case(name)
        struct_module = Module.concat(contract_module, struct_module_name)

        # @callback name(ops :: [{reference(), StructModule.t()}]) ::
        #   Skuld.Comp.Types.computation(%{reference() => return_type})
        result_map_type = {:%{}, [], [{{:reference, [], []}, return_type}]}
        comp_type = {:computation, [], [result_map_type]}

        quote do
          @callback unquote(name)(ops :: [{reference(), unquote(struct_module).t()}]) ::
                      Skuld.Comp.Types.unquote(comp_type)
        end
      end)

    quote do
      defmodule unquote(executor_module) do
        @moduledoc "Executor behaviour for `#{inspect(unquote(contract_module))}` queries."
        unquote_splicing(callbacks)
      end
    end
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
  # with_executor/2 Generation (skuld-avo)
  # -------------------------------------------------------------------

  defp generate_with_executor(operations) do
    quote do
      @doc """
      Install an executor module for all queries in this contract.

      The executor module must implement the `Executor` behaviour for this contract.

      ## Example

          comp
          |> MyContract.with_executor(MyContract.EctoExecutor)
          |> FiberPool.with_handler()
          |> Comp.run()
      """
      @spec with_executor(Skuld.Comp.Types.computation(), module()) ::
              Skuld.Comp.Types.computation()
      def with_executor(comp, executor_module) do
        Skuld.Fiber.FiberPool.BatchExecutor.with_executors(
          comp,
          Enum.map(
            unquote(Macro.escape(Enum.map(operations, & &1.name))),
            fn query_name ->
              {{__MODULE__, query_name},
               fn ops -> __MODULE__.__dispatch__(executor_module, query_name, ops) end}
            end
          )
        )
      end
    end
  end

  # -------------------------------------------------------------------
  # Bang Variant Generation (skuld-7hk)
  # -------------------------------------------------------------------

  defp generate_bang(_contract_module, %{
         name: name,
         param_names: param_names,
         param_types: param_types,
         return_type: return_type,
         bang_mode: bang_mode
       }) do
    bang_name = :"#{name}!"
    param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)
    spec_params = param_types

    unwrapped = Skuld.Effects.Port.Contract.extract_success_type(return_type)
    comp_type = {:computation, [], [unwrapped]}

    {doc_string, body_ast} =
      case bang_mode do
        :standard ->
          doc =
            "Fetch operation: `#{bang_name}/#{length(param_names)}`\n\nLike `#{name}/#{length(param_names)}` but unwraps `{:ok, value}` or dispatches `Throw` on error.\n"

          body =
            quote do
              Skuld.Comp.bind(
                unquote(name)(unquote_splicing(param_vars)),
                fn
                  {:ok, value} -> Skuld.Comp.pure(value)
                  {:error, reason} -> Skuld.Effects.Throw.throw(reason)
                end
              )
            end

          {doc, body}

        {:custom, unwrap_fn_ast} ->
          doc =
            "Fetch operation: `#{bang_name}/#{length(param_names)}`\n\nLike `#{name}/#{length(param_names)}` but applies a custom unwrap function, then unwraps `{:ok, value}` or dispatches `Throw` on error.\n"

          body =
            quote do
              Skuld.Comp.bind(
                unquote(name)(unquote_splicing(param_vars)),
                fn result ->
                  case unquote(unwrap_fn_ast).(result) do
                    {:ok, value} -> Skuld.Comp.pure(value)
                    {:error, reason} -> Skuld.Effects.Throw.throw(reason)
                  end
                end
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
