defmodule Skuld.Comp do
  @moduledoc """
  Skuld.Comp: Evidence-passing algebraic effects with scoped handlers.

  ## Core Concepts

  - **Computation**: `(env, k -> {result, env})` - a suspended computation
  - **Result**: Opaque value - framework doesn't impose shape
  - **Leave-scope**: Continuation chain for scope cleanup/control
  - **Suspend**: Sentinel struct that bypasses leave-scope

  ## Auto-Lifting

  Non-computation values are automatically lifted to `pure(value)`. This enables
  ergonomic patterns:

      comp do
        x <- State.get()
        _ <- if x > 5, do: Writer.tell(:big)  # nil auto-lifted when false
        x * 2  # final expression auto-lifted (no return needed)
      end

  ## Architecture

  Unlike Freyja's centralised interpreter, Skuld uses decentralised
  evidence-passing. Run acts as a **control authority** - it recognizes
  the Suspend sentinel and invokes the leave-scope chain - but treats
  results as opaque.

  Scoped effects (Reader.local, Catch) install leave-scope handlers
  that can clean up env or redirect control flow.
  """

  defmodule InvalidComputation do
    @moduledoc """
    Raised when a non-computation value is used where a computation is expected.

    This typically indicates a programming bug such as forgetting `return(value)`
    at the end of a comp block.
    """
    defexception [:message, :value]
  end

  # Sentinel protocol and types are in their own files:
  # - Skuld.Comp.Types (type definitions)
  # - Skuld.Comp.ISentinel (protocol)
  # - Skuld.Comp.Suspend (bypasses leave-scope)
  # - Skuld.Comp.Throw (error sentinel)
  alias Skuld.Comp.Env
  alias Skuld.Comp.ISentinel
  alias Skuld.Comp.Types
  alias Skuld.Comp.ConvertThrow

  #############################################################################
  ## Core Operations
  #############################################################################

  @doc "Lift a pure value into a computation"
  @spec pure(term()) :: Types.computation()
  def pure(value) do
    fn env, k -> k.(value, env) end
  end

  @doc """
  Lift a pure value into a computation.

  Alias for `pure/1`. Provided for ergonomic use both inside and outside
  `comp` blocks. Inside `comp` blocks, use the imported `return/1` from
  `Skuld.Comp.BaseOps`. Outside `comp` blocks, use `Comp.return/1` directly.

  ## Example

      # Inside a comp block (return is imported)
      comp do
        x <- State.get()
        return(x + 1)
      end

      # Outside a comp block
      fn x -> Comp.return(x * 2) end
  """
  @spec return(term()) :: Types.computation()
  def return(value), do: pure(value)

  @doc """
  Call a computation with validation and exception handling.

  Raises a helpful error if the value is not a valid computation (2-arity function).
  This catches common mistakes like forgetting `return(value)` at the end of a comp block.

  Elixir exceptions (raise/throw/exit) are caught and converted to Throw effects,
  allowing them to be handled uniformly with effect-based errors via `catch_error`.

  Note: `InvalidComputation` errors (validation failures) are re-raised rather than
  converted to Throws, since they represent programming bugs that should fail fast.
  """
  @spec call(Types.computation(), Types.env(), Types.k()) :: {Types.result(), Types.env()}
  def call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    kind, payload ->
      ConvertThrow.handle_exception(kind, payload, __STACKTRACE__, env)
  end

  # Auto-lift: non-computation values are treated as pure(value)
  # This enables ergonomic use like:
  #   _ <- if condition, do: Writer.tell(x)  # nil auto-lifted when false
  #   x + 1  # final expression auto-lifted (no return needed)
  def call(value, env, k) do
    k.(value, env)
  end

  @doc "Sequence computations"
  @spec bind(Types.computation(), (term() -> Types.computation())) :: Types.computation()
  def bind(comp, f) do
    fn env, k ->
      call(comp, env, fn a, env2 ->
        try do
          result = f.(a)
          call(result, env2, k)
        catch
          kind, payload ->
            ConvertThrow.handle_exception(kind, payload, __STACKTRACE__, env2)
        end
      end)
    end
  end

  @doc "identity continuation - for initial continuation & default leave-scope"
  def identity_k(val, env), do: {val, env}

  @doc """
  Run a computation to completion.

  Creates a fresh environment internally - all handler installation should
  be done via `with_handler` on the computation.

  Uses ISentinel protocol to determine completion behavior:
  - Suspend: bypasses leave-scope chain
  - Other values: invoke leave-scope chain

  ## Example

      {result, _env} =
        my_comp
        |> State.with_handler(0)
        |> Reader.with_handler(:config)
        |> Comp.run()
  """
  @spec run(Types.computation()) :: {Types.result(), Types.env()}
  def run(comp) do
    {result, final_env} =
      call(
        comp,
        Env.with_leave_scope(Env.new(), &identity_k/2),
        &identity_k/2
      )

    ISentinel.run(result, final_env)
  end

  @doc "Run a computation, extracting just the value (raises on Suspend/Throw)"
  @spec run!(Types.computation()) :: term()
  def run!(comp) do
    {result, _env} = run(comp)
    ISentinel.run!(result)
  end

  #############################################################################
  ## Effect Invocation
  #############################################################################

  @doc """
  Call an effect handler with exception handling.

  Similar to `call/3` but for 3-arity handlers. Exceptions in handler code
  are caught and converted to Throw effects.
  """
  @spec call_handler(Types.handler(), term(), Types.env(), Types.k()) ::
          {Types.result(), Types.env()}
  def call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    kind, payload ->
      ConvertThrow.handle_exception(kind, payload, __STACKTRACE__, env)
  end

  @doc "Invoke an effect operation"
  @spec effect(Types.sig(), term()) :: Types.computation()
  def effect(sig, args \\ nil) do
    fn env, k ->
      handler = Env.get_handler!(env, sig)
      call_handler(handler, args, env, k)
    end
  end

  #############################################################################
  ## Combinators
  #############################################################################

  @doc "Sequence computations, ignoring first result"
  @spec then_do(Types.computation(), Types.computation()) :: Types.computation()
  def then_do(comp1, comp2) do
    bind(comp1, fn _ -> comp2 end)
  end

  @doc "Map over a computation's result"
  @spec map(Types.computation(), (term() -> term())) :: Types.computation()
  def map(comp, f) do
    bind(comp, fn a -> pure(f.(a)) end)
  end

  @doc "Flatten nested computations"
  @spec flatten(Types.computation()) :: Types.computation()
  def flatten(comp) do
    fn env, k ->
      call(comp, env, fn inner, env2 ->
        call(inner, env2, k)
      end)
    end
  end

  @doc """
  Sequence a list of computations.

  Runs each computation in order, collecting results into a list.
  Uses a tail-recursive accumulator to avoid stack overflow on large lists.
  """
  @spec sequence([Types.computation()]) :: Types.computation()
  def sequence(comps), do: sequence_acc(comps, [])

  defp sequence_acc([], acc), do: pure(Enum.reverse(acc))

  defp sequence_acc([comp | rest], acc) do
    bind(comp, fn a -> sequence_acc(rest, [a | acc]) end)
  end

  @doc """
  Apply f to each element, sequence the resulting computations.

  Uses a tail-recursive accumulator to avoid stack overflow on large lists.
  """
  @spec traverse(list(), (term() -> Types.computation())) :: Types.computation()
  def traverse(list, f), do: traverse_acc(list, f, [])

  defp traverse_acc([], _f, acc), do: pure(Enum.reverse(acc))

  defp traverse_acc([h | t], f, acc) do
    bind(f.(h), fn a -> traverse_acc(t, f, [a | acc]) end)
  end

  @doc """
  Apply f to each element for side effects, discarding results.

  Like `traverse/2` but returns `:ok` instead of collecting results.
  Useful when you only care about effects (e.g., `Writer.tell`), not values.

  ## Example

      comp do
        _ <- Comp.each(items, &Writer.tell/1)
        return(:done)
      end
  """
  @spec each(list(), (term() -> Types.computation())) :: Types.computation()
  def each([], _f), do: pure(:ok)
  def each([h | t], f), do: bind(f.(h), fn _ -> each(t, f) end)

  #############################################################################
  ## Scoping Primitives
  #############################################################################

  @doc """
  Create a scoped computation with a final continuation for cleanup and result transformation.

  The `setup` function receives the current env and must return
  `{modified_env, finally_k}` where `finally_k :: (value, env) -> {value, env}`
  is a continuation that runs when the scope exits.

  This enables Koka-style `with` semantics where handlers can transform
  computation results (e.g., wrapping with collected state, logs, etc.).

  The `finally_k` continuation is called on both:
  - **Normal exit**: before continuing to outer computation
  - **Abnormal exit**: during leave-scope unwinding (e.g., throw)

  The previous leave-scope is automatically restored in both paths.

  The argument order is pipe-friendly (computation first).

  ## Example - Environment restoration only

      def local(modify, comp) do
        comp
        |> Skuld.Comp.scoped(fn env ->
          current = Env.get_state(env, @sig)
          modified_env = Env.put_state(env, @sig, modify.(current))
          finally_k = fn value, e -> {value, Env.put_state(e, @sig, current)} end
          {modified_env, finally_k}
        end)
      end

  ## Example - Result transformation (like EffectLogger)

      def with_logging(comp) do
        comp
        |> Skuld.Comp.scoped(fn env ->
          env_with_log = Env.put_state(env, :log, [])

          finally_k = fn value, e ->
            log = Env.get_state(e, :log)
            cleaned = Map.delete(e.state, :log)
            {{value, Enum.reverse(log)}, %{e | state: cleaned}}
          end

          {env_with_log, finally_k}
        end)
      end
  """
  @spec scoped(Types.computation(), (Types.env() -> {Types.env(), Types.leave_scope()})) ::
          Types.computation()
  def scoped(comp, setup) do
    fn env, outer_k ->
      previous_leave_scope = Env.get_leave_scope(env)
      {modified_env, finally_k} = setup.(env)

      # Normal exit: run finally_k then continue to outer
      # BUT if finally_k produces a throw, route through leave_scope instead
      normal_k = fn value, inner_env ->
        {new_value, final_env} =
          try do
            finally_k.(value, inner_env)
          catch
            kind, payload ->
              ConvertThrow.handle_exception(kind, payload, __STACKTRACE__, inner_env)
          end

        restored_env = Env.with_leave_scope(final_env, previous_leave_scope)

        case new_value do
          %__MODULE__.Throw{} ->
            # finally_k produced a throw - route through leave_scope
            previous_leave_scope.(new_value, restored_env)

          _ ->
            outer_k.(new_value, restored_env)
        end
      end

      # Abnormal exit: run finally_k during leave-scope unwinding
      my_leave_scope = fn result, inner_env ->
        {new_result, final_env} =
          try do
            finally_k.(result, inner_env)
          catch
            kind, payload ->
              ConvertThrow.handle_exception(kind, payload, __STACKTRACE__, inner_env)
          end

        previous_leave_scope.(new_result, Env.with_leave_scope(final_env, previous_leave_scope))
      end

      # comp.(env, k)
      call(comp, Env.with_leave_scope(modified_env, my_leave_scope), normal_k)
    end
  end

  @doc """
  Install a scoped handler for an effect.

  The handler is installed for the duration of `comp` and then restored
  to its previous state (or removed if there was no previous handler).

  This allows "shadowing" handlers - an inner computation can have its
  own handler for an effect while an outer handler exists.

  The argument order is pipe-friendly (computation first).

  ## Example

      # Create a computation with its own State handler
      inner =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          return(x)
        end
        |> Comp.with_handler(State, &State.handle/3)

      # Use it - inner State is independent of outer State
      outer = comp do
        _ <- State.put(100)
        result <- inner        # uses inner's handler
        y <- State.get()       # uses outer's handler, still 100
        return({result, y})
      end
  """
  @spec with_handler(Types.computation(), Types.sig(), Types.handler()) :: Types.computation()
  def with_handler(comp, sig, handler) do
    scoped(
      comp,
      fn env ->
        previous = Env.get_handler(env, sig)
        modified_env = Env.with_handler(env, sig, handler)

        finally_k = fn value, e ->
          restored_env =
            case previous do
              nil -> Env.delete_handler(e, sig)
              h -> Env.with_handler(e, sig, h)
            end

          {value, restored_env}
        end

        {modified_env, finally_k}
      end
    )
  end
end
