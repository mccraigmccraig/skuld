defmodule Skuld.Effects.Port do
  @moduledoc """
  Effect for dispatching parameterizable blocking calls to pluggable backends.

  This effect lets domain code express "call this function" without binding to a
  particular implementation. Each request specifies:

    * `mod` – module implementing the function
    * `name` – function name inside `mod`
    * `params` – keyword list of parameters

  ## Use Cases

  Port is ideal for wrapping any existing side-effecting Elixir code:

    * Database queries
    * HTTP API calls
    * File system operations
    * External service integrations
    * Legacy code that performs I/O

  ## Result Tuple Convention

  Port handlers should return `{:ok, value}` or `{:error, reason}` tuples.
  This convention enables two request modes:

    * `request/3` – returns the result tuple as-is for caller to handle
    * `request!/3` – unwraps `{:ok, value}` or dispatches `Throw` on error

  ## Example

      alias Skuld.Effects.Port

      # Implementation returns result tuples
      defmodule MyApp.UserQueries do
        def find_by_id(id: id) do
          case Repo.get(User, id) do
            nil -> {:error, {:not_found, User, id}}
            user -> {:ok, user}
          end
        end
      end

      # Using request/3 - returns result tuple
      defcomp find_user(id) do
        result <- Port.request(MyApp.UserQueries, :find_by_id, id: id)
        case result do
          {:ok, user} -> return(user)
          {:error, _} -> return(nil)
        end
      end

      # Using request!/3 - unwraps or throws
      defcomp find_user!(id) do
        user <- Port.request!(MyApp.UserQueries, :find_by_id, id: id)
        return(user)
      end

      # Runtime: dispatch to actual modules
      find_user!(123)
      |> Port.with_handler(%{MyApp.UserQueries => :direct})
      |> Throw.with_handler()
      |> Comp.run!()

      # Test: stub responses with exact key matching
      find_user!(123)
      |> Port.with_test_handler(%{
        Port.key(MyApp.UserQueries, :find_by_id, id: 123) => {:ok, %{id: 123, name: "Alice"}}
      })
      |> Throw.with_handler()
      |> Comp.run!()

      # Test: function-based handler with pattern matching
      find_user!(123)
      |> Port.with_fn_handler(fn
        MyApp.UserQueries, :find_by_id, [id: id] -> {:ok, %{id: id, name: "User \#{id}"}}
      end)
      |> Throw.with_handler()
      |> Comp.run!()
  """

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

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

  @typedoc "Module implementing `name/1`"
  @type port_module :: module()

  @typedoc "Function exported by `port_module`"
  @type port_name :: atom()

  @typedoc "Keyword list of parameters"
  @type params :: keyword()

  @typedoc """
  Registry entry for dispatching requests.

    * `:direct` – call `apply(mod, name, [params])`
    * `function` (arity 3) – `fun.(mod, name, params)`
    * `{module, function}` – invokes `apply(module, function, [mod, name, params])`
    * `module` – invokes `module.handle_port(mod, name, params)`
  """
  @type resolver ::
          :direct
          | (port_module(), port_name(), params() -> term())
          | {module(), atom()}
          | module()

  @typedoc "Registry mapping port modules to resolvers"
  @type registry :: %{port_module() => resolver()}

  @typedoc "Function handler for test scenarios - receives (mod, name, params)"
  @type fn_handler :: (port_module(), port_name(), params() -> term())

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Build a request for the given module/function.

  Returns the result tuple `{:ok, value}` or `{:error, reason}` as-is,
  allowing the caller to handle errors explicitly.

  ## Example

      Port.request(MyApp.UserQueries, :find_by_id, id: 123)
      # => {:ok, %User{...}} or {:error, {:not_found, User, 123}}
  """
  @spec request(port_module(), port_name(), params()) :: Types.computation()
  def request(mod, name, params \\ []) do
    Comp.effect(@sig, %Request{mod: mod, name: name, params: params})
  end

  @doc """
  Build a request that unwraps the result or throws on error.

  Expects the handler to return `{:ok, value}` or `{:error, reason}`.
  On success, returns the unwrapped `value`. On error, dispatches a
  `Skuld.Effects.Throw` effect with the `reason`.

  Requires a `Throw.with_handler/1` in the handler chain.

  ## Example

      Port.request!(MyApp.UserQueries, :find_by_id, id: 123)
      # => %User{...} or throws {:not_found, User, 123}
  """
  @spec request!(port_module(), port_name(), params()) :: Types.computation()
  def request!(mod, name, params \\ []) do
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

  Parameters are normalized so that keyword lists with the same keys and values
  produce the same key, independent of key ordering.

  ## Example

      Port.key(MyApp.UserQueries, :find_by_id, id: 123)
  """
  @spec key(port_module(), port_name(), params()) ::
          {port_module(), port_name(), binary()}
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

  defp canonical_term(list) when is_list(list) do
    if Keyword.keyword?(list) do
      # Keyword list - sort by key for canonical form
      list
      |> Enum.map(fn {k, v} -> {k, canonical_term(v)} end)
      |> Enum.sort_by(&elem(&1, 0))
    else
      # Regular list - preserve order
      Enum.map(list, &canonical_term/1)
    end
  end

  defp canonical_term(tuple) when is_tuple(tuple) do
    {:__tuple__, tuple |> Tuple.to_list() |> Enum.map(&canonical_term/1)}
  end

  defp canonical_term(other), do: other

  #############################################################################
  ## Handler Installation - Runtime
  #############################################################################

  @doc """
  Install a scoped Port handler for a computation.

  Pass a registry map keyed by module to control how requests are
  dispatched. Each entry can be one of:

    * `:direct` – call `apply(mod, name, [params])`
    * `function` (arity 3) – `fun.(mod, name, params)`
    * `{module, function}` – invokes `apply(module, function, [mod, name, params])`
    * `module` – invokes `module.handle_port(mod, name, params)`

  Handlers may return any value. To signal errors, raise or use
  `Skuld.Effects.Throw.throw/1`.

  ## Example

      my_comp
      |> Port.with_handler(%{
        MyApp.UserQueries => :direct,
        MyApp.OrderQueries => MyApp.CachedHandler
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
  Install Port handler via catch clause syntax.

  Config is the registry map, or `{registry, opts}`:

      catch
        Port -> %{MyModule => :direct}
        Port -> {%{MyModule => :direct}, output: fn r, s -> {r, s} end}
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, {registry, opts}) when is_map(registry) and is_list(opts),
    do: with_handler(comp, registry, opts)

  def __handle__(comp, registry) when is_map(registry), do: with_handler(comp, registry)

  #############################################################################
  ## Handler Installation - Test (Map-based)
  #############################################################################

  @doc """
  Install a test handler with canned responses.

  Provide a map of responses keyed by `Port.key/3`. Missing keys will
  throw `{:port_not_stubbed, key}` unless a `fallback:` function is provided.

  ## Options

    * `:fallback` - A function `(mod, name, params) -> result` to call when
      no exact key match is found. Useful for handling dynamic parameters
      while still using exact matching for known cases.
    * `:output` - Transform result when leaving scope
    * `:suspend` - Decorate Suspend values when yielding

  ## Example

      responses = %{
        Port.key(MyApp.UserQueries, :find_by_id, id: 123) => {:ok, %{name: "Alice"}},
        Port.key(MyApp.UserQueries, :find_by_id, id: 456) => {:error, :not_found}
      }

      my_comp
      |> Port.with_test_handler(responses)
      |> Throw.with_handler()
      |> Comp.run!()

      # With fallback for dynamic cases
      my_comp
      |> Port.with_test_handler(responses, fallback: fn
        MyApp.AuditQueries, _name, _params -> :ok
        mod, name, params -> raise "Unhandled: \#{inspect(mod)}.\#{name}"
      end)
      |> Throw.with_handler()
      |> Comp.run!()
  """
  @spec with_test_handler(Types.computation(), map(), keyword()) :: Types.computation()
  def with_test_handler(comp, responses, opts \\ []) when is_map(responses) do
    fallback = Keyword.get(opts, :fallback)
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    state =
      if fallback do
        {:test, responses, fallback}
      else
        {:test, responses}
      end

    comp
    |> Comp.with_scoped_state(@state_key, state, scoped_opts)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  #############################################################################
  ## Handler Installation - Test (Function-based)
  #############################################################################

  @doc """
  Install a function-based test handler.

  The handler function receives `(mod, name, params)` and can use Elixir's
  full pattern matching power including guards, pins, and wildcards.

  If no function clause matches, throws `{:port_not_handled, mod, name, params}`.

  ## Example

      handler = fn
        # Pin specific values
        MyApp.UserQueries, :find_by_id, [id: ^expected_id] ->
          {:ok, %{id: expected_id, name: "Expected"}}

        # Match any value with wildcard
        MyApp.UserQueries, :find_by_id, [id: _any_id] ->
          {:ok, %{id: "default", name: "Default"}}

        # Match with guards
        MyApp.Queries, :paginate, [limit: l] when l > 100 ->
          {:error, :limit_too_high}

        # Match specific module, any function
        MyApp.AuditQueries, _function, _params ->
          :ok

        # Catch-all (optional)
        mod, fun, params ->
          raise "Unhandled: \#{inspect(mod)}.\#{fun}(\#{inspect(params)})"
      end

      my_comp
      |> Port.with_fn_handler(handler)
      |> Throw.with_handler()
      |> Comp.run!()

  ## Property-Based Testing

  Function handlers are ideal for property-based tests where exact values
  aren't known upfront:

      property "user lookup succeeds" do
        check all user_id <- uuid_generator() do
          handler = fn
            UserQueries, :find_by_id, [id: ^user_id] ->
              {:ok, %{id: user_id, name: "Test User"}}
          end

          result =
            find_user(user_id)
            |> Port.with_fn_handler(handler)
            |> Throw.with_handler()
            |> Comp.run!()

          assert {:ok, _} = result
        end
      end
  """
  @spec with_fn_handler(Types.computation(), fn_handler(), keyword()) :: Types.computation()
  def with_fn_handler(comp, handler_fn, opts \\ []) when is_function(handler_fn, 3) do
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    comp
    |> Comp.with_scoped_state(@state_key, {:fn_handler, handler_fn}, scoped_opts)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @impl Skuld.Comp.IHandle
  def handle(%Request{mod: mod, name: name, params: params}, env, k) do
    case Env.get_state(env, @state_key) do
      {:runtime, registry} ->
        handle_runtime(registry, mod, name, params, env, k)

      {:test, responses} ->
        handle_test(responses, nil, mod, name, params, env, k)

      {:test, responses, fallback} ->
        handle_test(responses, fallback, mod, name, params, env, k)

      {:fn_handler, handler_fn} ->
        handle_fn(handler_fn, mod, name, params, env, k)

      nil ->
        # No handler state - this shouldn't happen if with_handler was called
        {%ThrowResult{error: {:port_handler_not_configured, mod, name}}, env}
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

  defp handle_test(responses, fallback, mod, name, params, env, k) do
    request_key = key(mod, name, params)

    case Map.fetch(responses, request_key) do
      {:ok, result} ->
        k.(result, env)

      :error when is_function(fallback, 3) ->
        # Try fallback function
        handle_fn(fallback, mod, name, params, env, k)

      :error ->
        # No match and no fallback
        {%ThrowResult{error: {:port_not_stubbed, request_key}}, env}
    end
  end

  defp handle_fn(handler_fn, mod, name, params, env, k) do
    result = handler_fn.(mod, name, params)
    k.(result, env)
  rescue
    e in FunctionClauseError ->
      # No matching clause - report what we received
      {%ThrowResult{error: {:port_not_handled, mod, name, params, e}}, env}

    e ->
      # Other error in handler
      {%ThrowResult{error: {:port_handler_error, mod, name, e}}, env}
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
            {:error, {:port_failed, mod, name, exception}}
        end

      :error ->
        {:error, {:unknown_port_module, mod}}
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
    if function_exported?(module, :handle_port, 3) do
      module.handle_port(mod, name, params)
    else
      raise ArgumentError,
            "#{inspect(module)} must export handle_port/3 to be used as a Port handler entry"
    end
  end
end
