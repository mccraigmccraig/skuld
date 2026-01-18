defmodule Skuld.Effects.Query do
  @moduledoc """
  Backend-agnostic data query effect.

  This effect lets domain code express "run this query" without binding to a
  particular storage layer. Each request specifies:

    * `mod` – module implementing the query
    * `name` – function name inside `mod`
    * `params` – map/struct of query parameters

  ## Result Tuple Convention

  Query handlers should return `{:ok, value}` or `{:error, reason}` tuples.
  This convention enables two request modes:

    * `request/3` – returns the result tuple as-is for caller to handle
    * `request!/3` – unwraps `{:ok, value}` or dispatches `Throw` on error

  ## Example

      alias Skuld.Effects.Query

      # Query implementation returns result tuples
      defmodule MyApp.UserQueries do
        def find_by_id(%{id: id}) do
          case Repo.get(User, id) do
            nil -> {:error, {:not_found, User, id}}
            user -> {:ok, user}
          end
        end
      end

      # Using request/3 - returns result tuple
      defcomp find_user(id) do
        result <- Query.request(MyApp.UserQueries, :find_by_id, %{id: id})
        case result do
          {:ok, user} -> return(user)
          {:error, _} -> return(nil)
        end
      end

      # Using request!/3 - unwraps or throws
      defcomp find_user!(id) do
        user <- Query.request!(MyApp.UserQueries, :find_by_id, %{id: id})
        return(user)
      end

      # Runtime: dispatch to actual query modules
      find_user!(123)
      |> Query.with_handler(%{MyApp.UserQueries => :direct})
      |> Throw.with_handler()
      |> Comp.run!()

      # Test: stub responses (use result tuples)
      find_user!(123)
      |> Query.with_test_handler(%{
        Query.key(MyApp.UserQueries, :find_by_id, %{id: 123}) => {:ok, %{id: 123, name: "Alice"}}
      })
      |> Throw.with_handler()
      |> Comp.run!()
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Throw, as: ThrowResult
  alias Skuld.Comp.Types
  alias Skuld.Effects.Throw

  @sig __MODULE__
  @state_key {__MODULE__, :registry}

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Request, [:mod, :name, :params])

  #############################################################################
  ## Types
  #############################################################################

  @typedoc "Query module implementing `name/1`"
  @type query_module :: module()

  @typedoc "Function exported by `query_module`"
  @type query_name :: atom()

  @typedoc "Opaque parameter payload"
  @type params :: map() | struct()

  @typedoc """
  Registry entry for dispatching queries.

    * `:direct` – call `apply(mod, name, [params])`
    * `function` (arity 3) – `fun.(mod, name, params)`
    * `{module, function}` – invokes `apply(module, function, [mod, name, params])`
    * `module` – invokes `module.handle_query(mod, name, params)`
  """
  @type resolver ::
          :direct
          | (query_module(), query_name(), params() -> term())
          | {module(), atom()}
          | module()

  @typedoc "Registry mapping query modules to resolvers"
  @type registry :: %{query_module() => resolver()}

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Build a query request for the given module/function.

  Returns the result tuple `{:ok, value}` or `{:error, reason}` as-is,
  allowing the caller to handle errors explicitly.

  ## Example

      Query.request(MyApp.UserQueries, :find_by_id, %{id: 123})
      # => {:ok, %User{...}} or {:error, {:not_found, User, 123}}
  """
  @spec request(query_module(), query_name(), params()) :: Types.computation()
  def request(mod, name, params \\ %{}) do
    Comp.effect(@sig, %Request{mod: mod, name: name, params: params})
  end

  @doc """
  Build a query request that unwraps the result or throws on error.

  Expects the query handler to return `{:ok, value}` or `{:error, reason}`.
  On success, returns the unwrapped `value`. On error, dispatches a
  `Skuld.Effects.Throw` effect with the `reason`.

  Requires a `Throw.with_handler/1` in the handler chain.

  ## Example

      Query.request!(MyApp.UserQueries, :find_by_id, %{id: 123})
      # => %User{...} or throws {:not_found, User, 123}
  """
  @spec request!(query_module(), query_name(), params()) :: Types.computation()
  def request!(mod, name, params \\ %{}) do
    Comp.bind(request(mod, name, params), fn
      {:ok, value} -> Comp.pure(value)
      {:error, reason} -> Throw.throw(reason)
    end)
  end

  #############################################################################
  ## Key Generation (for test stubs)
  #############################################################################

  @doc """
  Build a canonical key usable with `with_test_handler/2`.

  Parameters are normalized so that structurally-equal maps/structs produce the
  same key, independent of key ordering.

  ## Example

      Query.key(MyApp.UserQueries, :find_by_id, %{id: 123})
  """
  @spec key(query_module(), query_name(), params()) ::
          {query_module(), query_name(), binary()}
  def key(mod, name, params) do
    {mod, name, normalize_params(params)}
  end

  @doc false
  @spec normalize_params(term()) :: binary()
  def normalize_params(params) do
    params
    |> canonical_term()
    |> :erlang.term_to_binary()
  end

  defp canonical_term(%_{} = struct) do
    # Convert struct to list of {key, value} pairs including __struct__
    # Don't use Map.put back as that creates a map matching %_{} again
    struct_name = struct.__struct__

    struct
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, canonical_term(v)} end)
    |> Enum.concat([{:__struct__, struct_name}])
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {k, canonical_term(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)

  defp canonical_term(tuple) when is_tuple(tuple) do
    {:__tuple__, tuple |> Tuple.to_list() |> Enum.map(&canonical_term/1)}
  end

  defp canonical_term(other), do: other

  #############################################################################
  ## Handler Installation - Runtime
  #############################################################################

  @doc """
  Install a scoped Query handler for a computation.

  Pass a registry map keyed by query module to control how queries are
  dispatched. Each entry can be one of:

    * `:direct` – call `apply(mod, name, [params])`
    * `function` (arity 3) – `fun.(mod, name, params)`
    * `{module, function}` – invokes `apply(module, function, [mod, name, params])`
    * `module` – invokes `module.handle_query(mod, name, params)`

  Handlers may return any value. To signal errors, raise or use
  `Skuld.Effects.Throw.throw/1`.

  ## Example

      my_comp
      |> Query.with_handler(%{
        MyApp.UserQueries => :direct,
        MyApp.OrderQueries => MyApp.CachedQueryHandler
      })
      |> Comp.run!()
  """
  @spec with_handler(Types.computation(), registry(), keyword()) :: Types.computation()
  def with_handler(comp, registry \\ %{}, opts \\ []) do
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    comp
    |> Comp.with_scoped_state(@state_key, {:runtime, registry}, scoped_opts)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  @doc """
  Install Query handler via catch clause syntax.

  Config is the registry map, or `{registry, opts}`:

      catch
        Query -> %{MyQueries => :direct}
        Query -> {%{MyQueries => :direct}, output: fn r, s -> {r, s} end}
  """
  @impl Skuld.Comp.IHandler
  def __handle__(comp, {registry, opts}) when is_map(registry) and is_list(opts),
    do: with_handler(comp, registry, opts)

  def __handle__(comp, registry) when is_map(registry), do: with_handler(comp, registry)

  #############################################################################
  ## Handler Installation - Test
  #############################################################################

  @doc """
  Install a test handler with canned responses.

  Provide a map of responses keyed by `Query.key/3`. Missing keys will
  throw `{:query_not_stubbed, key}`.

  ## Example

      responses = %{
        Query.key(MyApp.UserQueries, :find_by_id, %{id: 123}) => %{id: 123, name: "Alice"},
        Query.key(MyApp.UserQueries, :find_by_id, %{id: 456}) => nil
      }

      my_comp
      |> Query.with_test_handler(responses)
      |> Throw.with_handler()
      |> Comp.run!()
  """
  @spec with_test_handler(Types.computation(), map(), keyword()) :: Types.computation()
  def with_test_handler(comp, responses, opts \\ []) when is_map(responses) do
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    comp
    |> Comp.with_scoped_state(@state_key, {:test, responses}, scoped_opts)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(%Request{mod: mod, name: name, params: params}, env, k) do
    case Env.get_state(env, @state_key) do
      {:runtime, registry} ->
        handle_runtime(registry, mod, name, params, env, k)

      {:test, responses} ->
        handle_test(responses, mod, name, params, env, k)

      nil ->
        # No handler state - this shouldn't happen if with_handler was called
        {%ThrowResult{error: {:query_handler_not_configured, mod, name}}, env}
    end
  end

  defp handle_runtime(registry, mod, name, params, env, k) do
    case dispatch(registry, mod, name, params) do
      {:ok, result} ->
        k.(result, env)

      {:error, reason} ->
        # Return Throw sentinel directly - it will be handled by leave_scope chain
        {%ThrowResult{error: reason}, env}
    end
  end

  defp handle_test(responses, mod, name, params, env, k) do
    query_key = key(mod, name, params)

    case Map.fetch(responses, query_key) do
      {:ok, result} ->
        k.(result, env)

      :error ->
        # Return Throw sentinel directly - it will be handled by leave_scope chain
        {%ThrowResult{error: {:query_not_stubbed, query_key}}, env}
    end
  end

  #############################################################################
  ## Dispatch Logic
  #############################################################################

  defp dispatch(registry, mod, name, params) when is_map(registry) do
    case Map.fetch(registry, mod) do
      {:ok, resolver} ->
        try do
          {:ok, invoke(resolver, mod, name, params)}
        rescue
          exception ->
            {:error, {:query_failed, mod, name, exception}}
        end

      :error ->
        {:error, {:unknown_query_module, mod}}
    end
  end

  defp invoke(:direct, mod, name, params) do
    apply(mod, name, [params])
  end

  defp invoke(fun, mod, name, params) when is_function(fun, 3) do
    fun.(mod, name, params)
  end

  defp invoke({module, function}, mod, name, params) do
    apply(module, function, [mod, name, params])
  end

  defp invoke(module, mod, name, params) when is_atom(module) do
    if function_exported?(module, :handle_query, 3) do
      module.handle_query(mod, name, params)
    else
      raise ArgumentError,
            "#{inspect(module)} must export handle_query/3 to be used as a Query handler entry"
    end
  end
end
