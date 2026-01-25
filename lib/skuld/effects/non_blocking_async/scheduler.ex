defmodule Skuld.Effects.NonBlockingAsync.Scheduler do
  @moduledoc """
  Cooperative scheduler for running multiple NonBlockingAsync computations.

  The scheduler runs computations until they yield `%AwaitSuspend{}`,
  tracks their await requests, and resumes them when completions arrive.

  ## Single Computation

      comp do
        h <- NonBlockingAsync.async(work())
        NonBlockingAsync.await(h)
      end
      |> NonBlockingAsync.with_handler()
      |> Scheduler.run_one()

  ## Multiple Computations

      Scheduler.run([
        workflow(user1),
        workflow(user2),
        workflow(user3)
      ])

  ## How It Works

  1. Computations are run until they produce a result or yield
  2. `%AwaitSuspend{}` yields are tracked - the scheduler waits for completions
  3. `%Suspend{}` yields are passed through to the caller (external input needed)
  4. When completions arrive (task done, timer fired), wake conditions are checked
  5. Ready computations are added to a FIFO run queue
  6. The scheduler continues until all computations complete or yield externally

  ## Error Handling

  By default, errors in one computation are logged and other computations continue.
  Configure via options:

      Scheduler.run(comps, on_error: :stop)           # Stop on first error
      Scheduler.run(comps, on_error: {:callback, fn}) # Custom handler
  """

  require Logger

  alias __MODULE__.Completion
  alias __MODULE__.State
  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Suspend
  alias Skuld.Effects.NonBlockingAsync.AwaitRequest.TimerTarget
  alias Skuld.Effects.NonBlockingAsync.AwaitSuspend

  @type computation :: Comp.Types.computation()
  @type result :: {:done, [term()]} | {:suspended, Suspend.t(), State.t()} | {:error, term()}

  #############################################################################
  ## Public API
  #############################################################################

  @doc """
  Run a single computation until completion or external yield.

  Returns:
  - `{:done, result}` - Computation completed with result
  - `{:suspended, %Suspend{}, resume}` - Computation yielded for external input
  - `{:error, reason}` - Computation failed
  """
  @spec run_one(computation(), keyword()) ::
          {:done, term()} | {:suspended, Suspend.t(), fun()} | {:error, term()}
  def run_one(comp, opts \\ []) do
    state = State.new(opts)

    case run_until_suspend(comp) do
      {:done, result} ->
        {:done, result}

      %AwaitSuspend{request: request, resume: resume} ->
        # Track and run loop
        state = State.add_suspension(state, request.id, request, resume)
        state = start_timers(state, request)
        run_loop(state)

      %Suspend{resume: resume} = suspend ->
        # External yield - return to caller with resume function
        resume_fn = fn value ->
          resumed_result = resume.(value)
          # Resume returns {result, env} or a suspension
          handle_resumed(resumed_result, opts)
        end

        {:suspended, suspend, resume_fn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Run multiple computations cooperatively until all complete.

  Returns `{:done, results}` with results in the same order as input computations,
  or `{:suspended, suspend, state}` if any computation yields for external input.

  ## Options

  - `:on_error` - Error handling strategy
    - `:log_and_continue` (default) - Log error, store `:error` as result
    - `:stop` - Stop scheduler on first error
    - `{:callback, fun}` - Call `fun.(error, state)` to handle
  """
  @spec run([computation()], keyword()) :: result()
  def run(computations, opts \\ []) when is_list(computations) do
    state = State.new(opts)

    # Assign IDs to track result ordering
    indexed_comps = Enum.with_index(computations)

    # Spawn all computations
    state =
      Enum.reduce(indexed_comps, state, fn {comp, idx}, acc ->
        spawn_computation(acc, comp, {:index, idx})
      end)

    # Run until all complete
    run_loop(state)
  end

  #############################################################################
  ## Core Loop
  #############################################################################

  defp run_loop(state) do
    case run_ready(state) do
      {:continue, state} ->
        run_loop(state)

      {:suspended, %Suspend{} = suspend, state} ->
        # External yield - return to caller
        {:suspended, suspend, state}

      {:done, state} ->
        # All done - extract results
        {:done, state.completed}

      {:receive, state} ->
        # Nothing ready - wait for message
        receive_and_continue(state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Run one ready computation from the queue
  defp run_ready(state) do
    case State.dequeue_one(state) do
      {:empty, state} ->
        # Nothing in run queue
        if State.active?(state) do
          {:receive, state}
        else
          {:done, state}
        end

      {:ok, {request_id, resume, results}, state} ->
        # Run the resumed computation
        case run_resume(resume, results) do
          {:done, result} ->
            # Computation finished
            state = State.record_completed(state, request_id, result)
            {:continue, state}

          %AwaitSuspend{request: request, resume: new_resume} ->
            # Suspended again on new await
            state = State.add_suspension(state, request.id, request, new_resume)
            state = start_timers(state, request)
            {:continue, state}

          %Suspend{} = suspend ->
            # External yield - pause this computation
            {:suspended, suspend, state}

          {:error, reason} ->
            handle_computation_error(state, request_id, reason)
        end
    end
  end

  # Wait for a message and process it
  defp receive_and_continue(state) do
    receive do
      msg ->
        case Completion.match(msg) do
          {:completed, target_key, result} ->
            case State.record_completion(state, target_key, result) do
              {:woke, _request_id, _wake_result, state} ->
                run_loop(state)

              {:waiting, state} ->
                run_loop(state)
            end

          {:yielded, _target_key, suspend} ->
            # A child computation yielded - need external handling
            # For now, treat this as an external yield
            {:suspended, suspend, state}

          :unknown ->
            # Unknown message - log and continue
            Logger.debug("Scheduler received unknown message: #{inspect(msg)}")
            run_loop(state)
        end
    end
  end

  #############################################################################
  ## Computation Running
  #############################################################################

  # Spawn a computation and run it until it suspends
  defp spawn_computation(state, comp, tag) do
    case run_until_suspend(comp) do
      {:done, result} ->
        # Completed immediately
        State.record_completed(state, tag, result)

      %AwaitSuspend{request: request, resume: resume} ->
        # Waiting on async
        state = State.add_suspension(state, request.id, request, resume)
        state = put_in(state.completed[request.id], {:tag, tag})
        start_timers(state, request)

      %Suspend{} = _suspend ->
        # External yield on first run - record as pending external
        # This is a bit unusual - typically computations start with async work
        Logger.warning("Computation yielded externally on spawn - not fully supported yet")
        State.record_completed(state, tag, {:error, :external_yield_on_spawn})

      {:error, reason} ->
        State.record_completed(state, tag, {:error, reason})
    end
  end

  # Run a computation until it returns a value or suspends
  defp run_until_suspend(comp) do
    env = Env.new()

    try do
      case Comp.call(comp, env, fn v, _e -> {:done, v} end) do
        {:done, result} ->
          {:done, result}

        %AwaitSuspend{} = suspend ->
          suspend

        %Suspend{} = suspend ->
          suspend

        other ->
          # Handle other sentinel types
          if Comp.ISentinel.impl_for(other) do
            other
          else
            {:done, other}
          end
      end
    rescue
      e ->
        {:error, {:exception, e, __STACKTRACE__}}
    catch
      :throw, reason ->
        {:error, {:throw, reason}}

      :exit, reason ->
        {:error, {:exit, reason}}
    end
  end

  # Resume a suspended computation with results
  defp run_resume(resume, results) do
    try do
      case resume.(results) do
        {:done, result} ->
          {:done, result}

        {result, %Env{}} ->
          {:done, result}

        %AwaitSuspend{} = suspend ->
          suspend

        %Suspend{} = suspend ->
          suspend

        other ->
          if Comp.ISentinel.impl_for(other) do
            other
          else
            {:done, other}
          end
      end
    rescue
      e ->
        {:error, {:exception, e, __STACKTRACE__}}
    catch
      :throw, reason ->
        {:error, {:throw, reason}}

      :exit, reason ->
        {:error, {:exit, reason}}
    end
  end

  # Handle the result of resuming a suspended computation
  defp handle_resumed(result, opts) do
    case result do
      {:done, value} ->
        {:done, value}

      {value, %Env{}} ->
        {:done, value}

      %AwaitSuspend{request: request, resume: resume} ->
        # Back to scheduler loop
        state = State.new(opts)
        state = State.add_suspension(state, request.id, request, resume)
        state = start_timers(state, request)
        run_loop(state)

      %Suspend{resume: resume} = suspend ->
        # Another external yield
        resume_fn = fn value ->
          resumed_result = resume.(value)
          handle_resumed(resumed_result, opts)
        end

        {:suspended, suspend, resume_fn}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:done, other}
    end
  end

  #############################################################################
  ## Helpers
  #############################################################################

  # Start timers for any TimerTargets in the request
  defp start_timers(state, %{targets: targets}) do
    Enum.reduce(targets, state, fn
      %TimerTarget{} = timer, acc ->
        case TimerTarget.start(timer) do
          {:ok, _started_timer} ->
            acc

          {:already_expired, _timer} ->
            # Timer already expired - record completion immediately
            target_key = {:timer, timer.ref}

            case State.record_completion(acc, target_key, {:ok, :timeout}) do
              {:woke, _request_id, _wake_result, new_state} -> new_state
              {:waiting, new_state} -> new_state
            end
        end

      _other, acc ->
        acc
    end)
  end

  # Handle error in a computation
  defp handle_computation_error(state, request_id, reason) do
    case Keyword.get(state.opts, :on_error, :log_and_continue) do
      :log_and_continue ->
        Logger.error("Computation #{inspect(request_id)} failed: #{inspect(reason)}")
        state = State.record_completed(state, request_id, {:error, reason})
        {:continue, state}

      :stop ->
        {:error, reason}

      {:callback, fun} ->
        case fun.(reason, state) do
          {:continue, state} -> {:continue, state}
          {:stop, reason} -> {:error, reason}
        end
    end
  end
end
