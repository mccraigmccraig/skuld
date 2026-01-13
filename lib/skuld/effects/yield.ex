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

  def_op(YieldOp, [:value])

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Yield a value and suspend, waiting for input to resume"
  @spec yield(term()) :: Types.computation()
  def yield(value) do
    Comp.effect(@sig, %YieldOp{value: value})
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
      # [1] Capture outer leave_scope
      outer_leave_scope = Env.get_leave_scope(env)

      # [2] Create env with identity leave_scope (so yields come back to us as %Suspend{})
      loop_env = Env.with_leave_scope(env, &Comp.identity_k/2)

      # [3] Run the respond loop
      respond_loop(inner_comp, loop_env, responder, outer_leave_scope, outer_k)
    end
  end

  # The respond loop - runs inner_comp and handles yields
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp respond_loop(inner_comp, env, responder, outer_leave_scope, outer_k) do
    alias Skuld.Comp.Env

    # Run inner computation with identity leave_scope
    {result, result_env} = Comp.call(inner_comp, env, &Comp.identity_k/2)

    case result do
      %Comp.Suspend{value: yielded, resume: resume} ->
        # Inner computation yielded - run responder
        responder_comp = responder.(yielded)
        {resp_result, resp_env} = Comp.call(responder_comp, result_env, &Comp.identity_k/2)

        case resp_result do
          %Comp.Suspend{value: resp_yielded, resume: resp_resume} ->
            # Responder re-yielded - escape to outer handler
            # Wrap the resume to continue the respond loop when resumed
            wrapped_resume = fn input ->
              # Resume responder
              {resumed_result, resumed_env} = resp_resume.(input)

              case resumed_result do
                %Comp.Suspend{} = still_suspended ->
                  # Still suspended - wrap again
                  wrap_responder_resume(
                    still_suspended,
                    resumed_env,
                    resume,
                    responder,
                    outer_leave_scope
                  )

                %Comp.Throw{} = thrown ->
                  # Responder threw during resume - propagate through outer leave_scope
                  final_env = Env.with_leave_scope(resumed_env, outer_leave_scope)
                  outer_leave_scope.(thrown, final_env)

                resp_value ->
                  # Responder completed - resume inner and continue loop
                  # Build a continuation computation from the resume
                  inner_cont = fn cont_env, cont_k ->
                    {inner_result, inner_env} = resume.(resp_value)
                    # Replace env.state with inner_env.state but keep cont_env's leave_scope
                    merged_env = %{cont_env | state: inner_env.state}
                    cont_k.(inner_result, merged_env)
                  end

                  respond_loop(
                    inner_cont,
                    resumed_env,
                    responder,
                    outer_leave_scope,
                    &Comp.identity_k/2
                  )
              end
            end

            # Return suspend with outer leave_scope restored
            final_env = Env.with_leave_scope(resp_env, outer_leave_scope)
            {%Comp.Suspend{value: resp_yielded, resume: wrapped_resume}, final_env}

          %Comp.Throw{} = thrown ->
            # Responder threw - propagate through outer leave_scope
            final_env = Env.with_leave_scope(resp_env, outer_leave_scope)
            outer_leave_scope.(thrown, final_env)

          resp_value ->
            # Responder returned a value - resume inner computation and loop
            {resumed_result, resumed_env} = resume.(resp_value)
            # Merge state: use responder's state (which may have been modified)
            # but keep handlers and leave_scope from resumed_env
            merged_env = %{resumed_env | state: resp_env.state}

            case resumed_result do
              %Comp.Suspend{} = inner_suspend ->
                # Inner computation yielded again - continue loop
                # Wrap as a computation to continue the loop
                inner_cont = fn _cont_env, cont_k ->
                  cont_k.(inner_suspend, merged_env)
                end

                respond_loop(inner_cont, merged_env, responder, outer_leave_scope, outer_k)

              %Comp.Throw{} = thrown ->
                # Inner threw after resume - propagate through outer leave_scope
                final_env = Env.with_leave_scope(merged_env, outer_leave_scope)
                outer_leave_scope.(thrown, final_env)

              value ->
                # Inner completed - restore outer leave_scope and finish
                final_env = Env.with_leave_scope(merged_env, outer_leave_scope)
                outer_k.(value, final_env)
            end
        end

      %Comp.Throw{} = thrown ->
        # Inner threw - propagate through outer leave_scope
        final_env = Env.with_leave_scope(result_env, outer_leave_scope)
        outer_leave_scope.(thrown, final_env)

      value ->
        # Inner completed without yielding - restore outer leave_scope and finish
        final_env = Env.with_leave_scope(result_env, outer_leave_scope)
        outer_k.(value, final_env)
    end
  end

  # Wrap a still-suspended responder resume to continue the respond loop
  defp wrap_responder_resume(suspend, env, inner_resume, responder, outer_leave_scope) do
    alias Skuld.Comp.Env

    wrapped_resume = fn input ->
      {result, result_env} = suspend.resume.(input)

      case result do
        %Comp.Suspend{} = still_suspended ->
          wrap_responder_resume(
            still_suspended,
            result_env,
            inner_resume,
            responder,
            outer_leave_scope
          )

        %Comp.Throw{} = thrown ->
          final_env = Env.with_leave_scope(result_env, outer_leave_scope)
          outer_leave_scope.(thrown, final_env)

        resp_value ->
          # Responder completed - resume inner and continue loop
          {inner_result, inner_env} = inner_resume.(resp_value)
          # Merge state: use responder's state (result_env) with inner's handlers
          merged_env = %{inner_env | state: result_env.state}

          case inner_result do
            %Comp.Suspend{value: yielded, resume: next_resume} ->
              # Inner yielded again - need to continue respond loop
              # But we're in a resume context, so just return the suspend for now
              # The outer driver will call this resume, continuing the loop
              inner_cont = fn _cont_env, cont_k ->
                cont_k.(%Comp.Suspend{value: yielded, resume: next_resume}, merged_env)
              end

              respond_loop(
                inner_cont,
                merged_env,
                responder,
                outer_leave_scope,
                &Comp.identity_k/2
              )

            %Comp.Throw{} = thrown ->
              final_env = Env.with_leave_scope(merged_env, outer_leave_scope)
              outer_leave_scope.(thrown, final_env)

            value ->
              final_env = Env.with_leave_scope(merged_env, outer_leave_scope)
              {value, final_env}
          end
      end
    end

    final_env = Env.with_leave_scope(env, outer_leave_scope)
    {%Comp.Suspend{value: suspend.value, resume: wrapped_resume}, final_env}
  end

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

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @doc """
  Handler: returns Suspend struct with resume that captures env
  and invokes leave_scope when the resumed computation completes.
  """
  @impl Skuld.Comp.IHandler
  def handle(%YieldOp{value: value}, env, k) do
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
          (term() -> {:continue, term()} | {:stop, term()})
        ) ::
          {:done, term(), Types.env()}
          | {:stopped, term(), Types.env()}
          | {:thrown, term(), Types.env()}
  def run_with_driver(comp, driver) do
    case Comp.run(comp) do
      {%Comp.Suspend{value: yielded, resume: resume}, suspended_env} ->
        case driver.(yielded) do
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
  defp continue_with_driver(%Comp.Suspend{value: yielded, resume: resume}, env, driver) do
    case driver.(yielded) do
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
