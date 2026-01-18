defmodule Skuld.Effects.Yield do
  @moduledoc """
  Yield effect - coroutine-style suspension and resumption.

  Uses `%Skuld.Comp.Suspend{}` struct as the suspension result, which
  bypasses leave_scope in Run.

  ## Architecture

  - `yield(value)` suspends computation, returning `%Suspend{value, resume}`
  - The resume function captures the env, so caller just provides input
  - Run recognizes `%Suspend{}` and bypasses leave_scope
  - When resumed, the result goes through the leave_scope chain
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Yield, [:value])

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Yield a value and suspend, waiting for input to resume"
  @spec yield(term()) :: Types.computation()
  def yield(value) do
    Comp.effect(@sig, %Yield{value: value})
  end

  @doc "Yield without a value"
  @spec yield() :: Types.computation()
  def yield do
    yield(nil)
  end

  #############################################################################
  ## Yield Interception
  #############################################################################

  @doc """
  Intercept yields from a computation and respond to them.

  Similar to `Throw.catch_error/2`, but for yields instead of throws. The responder
  function receives the yielded value and returns a computation that produces the
  resume value. If the responder re-yields (calls `Yield.yield`), that yield
  propagates to the outer handler.

  ## Implementation Note

  This implementation wraps the Yield handler in the Env to intercept yields
  directly at the handler level. A previous implementation used a different
  approach: replacing the leave_scope with an identity function, running the
  inner computation to completion, then pattern matching on `%Suspend{}` results
  to detect yields. That approach was more complex (~180 lines vs ~80 lines),
  required manual env state merging, and interfered with other effects that
  rely on leave_scope (such as EffectLogger).

  ## Example

      # Handle all yields internally:
      comp do
        result <- Yield.respond(
          comp do
            x <- Yield.yield(:get_value)
            y <- Yield.yield(:get_another)
            x + y
          end,
          fn
            :get_value -> Comp.pure(10)
            :get_another -> Comp.pure(20)
          end
        )
        result
      end
      |> Yield.with_handler()
      |> Comp.run!()
      #=> 30

      # Responder can use effects:
      comp do
        result <- Yield.respond(
          comp do
            x <- Yield.yield(:get_state)
            x * 2
          end,
          fn :get_state -> State.get() end
        )
        result
      end
      |> State.with_handler(21)
      |> Yield.with_handler()
      |> Comp.run!()
      #=> 42

      # Unhandled yields propagate (re-yield):
      comp do
        result <- Yield.respond(
          comp do
            x <- Yield.yield(:handled)
            y <- Yield.yield(:not_handled)
            x + y
          end,
          fn
            :handled -> Comp.pure(10)
            other -> Yield.yield(other)  # re-yield to outer handler
          end
        )
        result
      end
      |> Yield.with_handler()
      |> Comp.run()
      # Returns %Suspend{value: :not_handled, ...}
  """
  @spec respond(Types.computation(), (term() -> Types.computation())) :: Types.computation()
  def respond(inner_comp, responder) do
    alias Skuld.Comp.Env

    fn env, outer_k ->
      # Get the current yield handler (will be used when responder re-yields)
      outer_yield_handler = Env.get_handler(env, @sig)

      # Create the wrapped handler and install it using with_handler for proper scoping
      wrapped_handler = make_wrapped_handler(responder, outer_yield_handler)

      wrapped_comp = Comp.with_handler(inner_comp, @sig, wrapped_handler)
      Comp.call(wrapped_comp, env, outer_k)
    end
  end

  defp make_wrapped_handler(responder, outer_yield_handler) do
    alias Skuld.Comp.Env

    fn %Yield{value: yielded_value}, yield_env, yield_k ->
      # Run the responder to get the resume value
      responder_comp = responder.(yielded_value)

      # Restore the outer handler for the responder (so re-yields go outward)
      responder_env =
        if outer_yield_handler do
          Env.with_handler(yield_env, @sig, outer_yield_handler)
        else
          Env.delete_handler(yield_env, @sig)
        end

      # The responder's continuation: when responder completes, resume the inner computation
      responder_k = fn resp_result, resp_env ->
        case resp_result do
          %Comp.Suspend{} = suspend ->
            # Responder re-yielded - we need to wrap the resume to continue
            # responding when eventually resumed
            wrapped_resume =
              wrap_respond_resume(
                suspend.resume,
                yield_k,
                responder,
                outer_yield_handler
              )

            {%Comp.Suspend{value: suspend.value, resume: wrapped_resume}, resp_env}

          %Comp.Throw{} = thrown ->
            # Responder threw - propagate directly
            {thrown, resp_env}

          resp_value ->
            # Responder returned a value - resume the inner computation
            # Re-install a wrapped handler for the continuation
            wrapped_handler = make_wrapped_handler(responder, outer_yield_handler)
            resumed_env = Env.with_handler(resp_env, @sig, wrapped_handler)
            yield_k.(resp_value, resumed_env)
        end
      end

      # Run the responder with its continuation (with outer handler)
      Comp.call(responder_comp, responder_env, responder_k)
    end
  end

  # Wrap a resume function to continue the respond loop after the responder is resumed
  defp wrap_respond_resume(original_resume, inner_k, responder, outer_yield_handler) do
    alias Skuld.Comp.Env

    fn input ->
      {result, result_env} = original_resume.(input)

      case result do
        %Comp.Suspend{} = suspend ->
          # Still suspended - wrap again
          wrapped_resume =
            wrap_respond_resume(
              suspend.resume,
              inner_k,
              responder,
              outer_yield_handler
            )

          {%Comp.Suspend{value: suspend.value, resume: wrapped_resume}, result_env}

        %Comp.Throw{} = thrown ->
          # Responder threw during resume
          {thrown, result_env}

        resp_value ->
          # Responder completed - resume the inner computation
          # Re-install a wrapped handler for inner_k
          wrapped_handler = make_wrapped_handler(responder, outer_yield_handler)
          resumed_env = Env.with_handler(result_env, @sig, wrapped_handler)
          inner_k.(resp_value, resumed_env)
      end
    end
  end

  @doc """
  Intercept yields locally within a computation.

  This is the `IHandler.intercept/2` implementation for Yield, enabling
  `{Yield, pattern}` clauses in `comp` block `catch` sections.

  Delegates to `respond/2`.
  """
  @impl Skuld.Comp.IHandler
  @spec intercept(Types.computation(), (term() -> Types.computation())) :: Types.computation()
  defdelegate intercept(comp, handler), to: __MODULE__, as: :respond

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped Yield handler for a computation.

  Installs the Yield handler for the duration of `comp`. The handler is
  restored/removed when `comp` completes or suspends.

  The argument order is pipe-friendly.

  ## Example

      # Wrap a computation with Yield handling
      comp_with_yield =
        comp do
          input <- Yield.yield(:question)
          return({:got, input})
        end
        |> Yield.with_handler()

      # Compose with other handlers
      my_comp
      |> Yield.with_handler()
      |> State.with_handler(0)
      |> Comp.run(Env.new())
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, @sig, &__MODULE__.handle/3)
  end

  @doc """
  Install Yield handler via catch clause syntax.

  Config is ignored (Yield handler takes no configuration):

      catch
        Yield -> nil
  """
  @impl Skuld.Comp.IHandler
  def __handle__(comp, _config), do: with_handler(comp)

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @doc """
  Handler: returns Suspend struct with resume that captures env
  and invokes leave_scope when the resumed computation completes.
  """
  @impl Skuld.Comp.IHandler
  def handle(%Yield{value: value}, env, k) do
    captured_resume = fn input ->
      {result, final_env} = k.(input, env)

      # If the result is another Suspend, don't invoke leave_scope yet
      # (it will be invoked when that suspend is eventually resolved)
      case result do
        %Comp.Suspend{} ->
          {result, final_env}

        _ ->
          # Invoke leave_scope chain on completion
          final_env.leave_scope.(result, final_env)
      end
    end

    {%Comp.Suspend{value: value, resume: captured_resume}, env}
  end

  #############################################################################
  ## Runner Utilities
  #############################################################################

  @doc """
  Run a computation with a driver function that handles yields.

  The driver receives yielded values and returns `{:continue, input}` or `{:stop, reason}`.

  The computation should already have handlers installed via `with_handler`.
  """
  @spec run_with_driver(
          Types.computation(),
          (value :: term(), data :: map() | nil -> {:continue, term()} | {:stop, term()})
        ) ::
          {:done, term(), Types.env()}
          | {:stopped, term(), Types.env()}
          | {:thrown, term(), Types.env()}
  def run_with_driver(comp, driver) do
    case Comp.run(comp) do
      {%Comp.Suspend{value: yielded, data: data, resume: resume}, suspended_env} ->
        case driver.(yielded, data) do
          {:continue, input} ->
            # Resume returns {result, env} with leave_scope already applied
            {result, new_env} = resume.(input)
            continue_with_driver(result, new_env, driver)

          {:stop, reason} ->
            {:stopped, reason, suspended_env}
        end

      {%Comp.Throw{error: error}, err_env} ->
        {:thrown, error, err_env}

      {value, final_env} ->
        {:done, value, final_env}
    end
  end

  # Continue processing after a resume
  defp continue_with_driver(
         %Comp.Suspend{value: yielded, data: data, resume: resume},
         env,
         driver
       ) do
    case driver.(yielded, data) do
      {:continue, input} ->
        {result, new_env} = resume.(input)
        continue_with_driver(result, new_env, driver)

      {:stop, reason} ->
        {:stopped, reason, env}
    end
  end

  defp continue_with_driver(%Comp.Throw{error: error}, env, _driver) do
    {:thrown, error, env}
  end

  defp continue_with_driver(value, env, _driver) do
    {:done, value, env}
  end

  @doc """
  Collect all yielded values until completion.

  Resumes with the provided input value (default: nil) each time.

  The computation should already have handlers installed via `with_handler`.
  """
  @spec collect(Types.computation(), term()) ::
          {:done, term(), [term()], Types.env()}
          | {:thrown, term(), [term()], Types.env()}
  def collect(comp, resume_input \\ nil) do
    case Comp.run(comp) do
      {%Comp.Suspend{} = suspend, suspended_env} ->
        do_collect(suspend, suspended_env, [], resume_input)

      {%Comp.Throw{error: error}, err_env} ->
        {:thrown, error, [], err_env}

      {value, final_env} ->
        {:done, value, [], final_env}
    end
  end

  defp do_collect(%Comp.Suspend{value: yielded, resume: resume}, _env, acc, input) do
    {result, new_env} = resume.(input)

    case result do
      %Comp.Suspend{} = suspend ->
        do_collect(suspend, new_env, [yielded | acc], input)

      %Comp.Throw{error: error} ->
        {:thrown, error, Enum.reverse([yielded | acc]), new_env}

      value ->
        {:done, value, Enum.reverse([yielded | acc]), new_env}
    end
  end

  @doc """
  Feed a list of inputs to a computation, collecting yields.

  Each yield consumes one input. If inputs run out, stops with remaining computation.

  The computation should already have handlers installed via `with_handler`.
  """
  @spec feed(Types.computation(), [term()]) ::
          {:done, term(), [term()], Types.env()}
          | {:suspended, term(), (term() -> {Types.result(), Types.env()}), [term()], Types.env()}
          | {:thrown, term(), [term()], Types.env()}
  def feed(comp, inputs) do
    case Comp.run(comp) do
      {%Comp.Suspend{} = suspend, suspended_env} ->
        do_feed(suspend, suspended_env, [], inputs)

      {%Comp.Throw{error: error}, err_env} ->
        {:thrown, error, [], err_env}

      {value, final_env} ->
        {:done, value, [], final_env}
    end
  end

  defp do_feed(%Comp.Suspend{value: yielded, resume: resume}, env, yielded_acc, []) do
    {:suspended, yielded, resume, Enum.reverse(yielded_acc), env}
  end

  defp do_feed(%Comp.Suspend{value: yielded, resume: resume}, _env, yielded_acc, [input | rest]) do
    {result, new_env} = resume.(input)

    case result do
      %Comp.Suspend{} = suspend ->
        do_feed(suspend, new_env, [yielded | yielded_acc], rest)

      %Comp.Throw{error: error} ->
        {:thrown, error, Enum.reverse([yielded | yielded_acc]), new_env}

      value ->
        {:done, value, Enum.reverse([yielded | yielded_acc]), new_env}
    end
  end
end
