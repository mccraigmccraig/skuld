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
    # Use a unique tag to identify this computation's result
    tag = make_ref()

    case run_until_suspend(comp) do
      {:done, result} ->
        {:done, result}

      %AwaitSuspend{request: request, resume: resume} ->
        # Track and run loop
        case State.add_suspension(state, request.id, request, resume) do
          {:ready, state} ->
            # Early completions satisfied immediately - run the ready computation
            state = %{state | completed: Map.put(state.completed, request.id, {:pending, tag})}
            run_one_loop(state, tag)

          {:suspended, state} ->
            # Associate the request_id with our tag for result extraction
            state = %{state | completed: Map.put(state.completed, request.id, {:pending, tag})}
            state = start_timers(state, request)
            run_one_loop(state, tag)
        end

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

  # Run loop for single computation - extracts the final result
  defp run_one_loop(state, tag) do
    case run_ready_one(state, tag) do
      {:continue, state} ->
        run_one_loop(state, tag)

      {:suspended, suspend, state} ->
        {:suspended, suspend, state}

      {:done, result} ->
        {:done, result}

      {:receive, state} ->
        receive_and_continue_one(state, tag)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Run one ready computation from the queue, tracking which is our target
  defp run_ready_one(state, tag) do
    case State.dequeue_one(state) do
      {:empty, state} ->
        if State.active?(state) do
          {:receive, state}
        else
          # Find our result by tag
          result = find_result_by_tag(state.completed, tag)
          {:done, result}
        end

      {:ok, {request_id, resume, results}, state} ->
        case run_resume(resume, results) do
          {:done, result} ->
            # Check if this is our computation (via the pending marker)
            state =
              case Map.get(state.completed, request_id) do
                {:pending, ^tag} ->
                  # This is our computation - store the actual result
                  %{state | completed: Map.put(state.completed, tag, result)}

                _ ->
                  State.record_completed(state, request_id, result)
              end

            {:continue, state}

          %AwaitSuspend{request: request, resume: new_resume} ->
            {status, state} = State.add_suspension(state, request.id, request, new_resume)

            # Transfer tag association to new request
            state =
              case Map.get(state.completed, request_id) do
                {:pending, ^tag} ->
                  %{
                    state
                    | completed:
                        state.completed
                        |> Map.delete(request_id)
                        |> Map.put(request.id, {:pending, tag})
                  }

                _ ->
                  state
              end

            case status do
              :ready ->
                # Early completions satisfied - computation already in run_queue
                {:continue, state}

              :suspended ->
                state = start_timers(state, request)
                {:continue, state}
            end

          %Suspend{} = suspend ->
            {:suspended, suspend, state}

          {:error, reason} ->
            handle_computation_error(state, request_id, reason)
        end
    end
  end

  # Wait for message for single computation
  defp receive_and_continue_one(state, tag) do
    receive do
      msg ->
        case Completion.match(msg) do
          {:completed, target_key, result} ->
            case State.record_completion(state, target_key, result) do
              {:woke, _request_id, _wake_result, state} ->
                run_one_loop(state, tag)

              {:waiting, state} ->
                run_one_loop(state, tag)
            end

          {:yielded, _target_key, suspend} ->
            {:suspended, suspend, state}

          :unknown ->
            Logger.debug("Scheduler received unknown message: #{inspect(msg)}")
            run_one_loop(state, tag)
        end
    end
  end

  # Find result by tag in completed map
  defp find_result_by_tag(completed, tag) do
    case Map.get(completed, tag) do
      nil ->
        # Fallback - find any non-pending result
        completed
        |> Enum.find_value(fn
          {_k, {:pending, _}} -> nil
          {_k, v} -> v
        end)

      result ->
        result
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

    # Spawn all computations (may return early on error with :stop option)
    case spawn_all(state, indexed_comps) do
      {:ok, state} ->
        # Run until all complete
        run_loop(state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Spawn all computations, stopping early if :on_error => :stop and one fails
  defp spawn_all(state, indexed_comps) do
    Enum.reduce_while(indexed_comps, {:ok, state}, fn {comp, idx}, {:ok, acc} ->
      case spawn_computation(acc, comp, {:index, idx}) do
        {:ok, new_state} ->
          {:cont, {:ok, new_state}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  #############################################################################
  ## Server API - For GenServer Integration
  #############################################################################

  @doc """
  Spawn a computation into existing scheduler state.

  Used by Scheduler.Server to add computations to a running scheduler.
  Returns `{:ok, tag, state}` or `{:error, reason}` depending on `:on_error` option.

  The `tag` can be used to retrieve the computation's result from `state.completed`.
  """
  @spec spawn_into(State.t(), computation(), term()) ::
          {:ok, term(), State.t()} | {:error, term()}
  def spawn_into(state, comp, tag \\ nil) do
    tag = tag || make_ref()

    case spawn_computation(state, comp, tag) do
      {:ok, state} -> {:ok, tag, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Handle a completion message and update scheduler state.

  Used by Scheduler.Server to process messages received via `handle_info`.
  Returns `{:ok, state}` if the message was processed, or `{:ignored, state}`
  if the message was not a recognized completion.
  """
  @spec handle_message(State.t(), term()) :: {:ok, State.t()} | {:ignored, State.t()}
  def handle_message(state, msg) do
    case Completion.match(msg) do
      {:completed, target_key, result} ->
        case State.record_completion(state, target_key, result) do
          {:woke, _request_id, _wake_result, state} ->
            {:ok, state}

          {:waiting, state} ->
            {:ok, state}
        end

      {:yielded, _target_key, _suspend} ->
        # External yield from a child - not supported in server mode yet
        Logger.warning("Scheduler.Server received external yield - not supported")
        {:ignored, state}

      :unknown ->
        {:ignored, state}
    end
  end

  @doc """
  Run ready computations without blocking.

  Used by Scheduler.Server to process the run queue after receiving messages.
  Returns `{:continue, state}` if there's more work that could be done,
  `{:idle, state}` if waiting for messages, or `{:done, state}` if all
  computations have completed.
  """
  @spec step(State.t()) :: {:continue, State.t()} | {:idle, State.t()} | {:done, State.t()}
  def step(state) do
    case run_ready(state) do
      {:continue, state} ->
        # More work available - continue stepping
        {:continue, state}

      {:receive, state} ->
        # Waiting for messages
        {:idle, state}

      {:done, state} ->
        # All computations finished
        {:done, state}

      {:suspended, _suspend, state} ->
        # External yield - treat as idle for server mode
        {:idle, state}

      {:error, _reason} = error ->
        # Propagate error
        error
    end
  end

  @doc """
  Run all ready computations until the queue is empty.

  A convenience function that calls `step/1` repeatedly until idle or done.
  """
  @spec drain_ready(State.t()) :: {:idle, State.t()} | {:done, State.t()} | {:error, term()}
  def drain_ready(state) do
    case step(state) do
      {:continue, state} -> drain_ready(state)
      other -> other
    end
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
            # Computation finished - resolve tag and store result
            state = record_with_tag_resolution(state, request_id, result)
            {:continue, state}

          %AwaitSuspend{request: request, resume: new_resume} ->
            # Suspended again on new await - transfer tag association
            state = transfer_tag_association(state, request_id, request.id)

            case State.add_suspension(state, request.id, request, new_resume) do
              {:ready, state} ->
                # Early completions satisfied immediately
                {:continue, state}

              {:suspended, state} ->
                state = start_timers(state, request)
                {:continue, state}
            end

          %Suspend{} = suspend ->
            # External yield - pause this computation
            {:suspended, suspend, state}

          {:error, reason} ->
            handle_computation_error(state, request_id, reason)
        end
    end
  end

  # Record result, resolving tag association if present
  defp record_with_tag_resolution(state, request_id, result) do
    case Map.get(state.completed, request_id) do
      {:tag, user_tag} ->
        # Store under user tag, clean up marker
        state
        |> put_in([Access.key(:completed), request_id], nil)
        |> update_in([Access.key(:completed)], &Map.delete(&1, request_id))
        |> put_in([Access.key(:completed), user_tag], result)

      _ ->
        # No tag association - store under request_id (used by run/2)
        State.record_completed(state, request_id, result)
    end
  end

  # Transfer tag association from old request to new request
  defp transfer_tag_association(state, old_request_id, new_request_id) do
    case Map.get(state.completed, old_request_id) do
      {:tag, user_tag} ->
        state
        |> update_in([Access.key(:completed)], &Map.delete(&1, old_request_id))
        |> put_in([Access.key(:completed), new_request_id], {:tag, user_tag})

      _ ->
        state
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
  # Returns {:ok, state} or {:error, reason} depending on :on_error option
  defp spawn_computation(state, comp, tag) do
    case run_until_suspend(comp) do
      {:done, result} ->
        # Completed immediately
        {:ok, State.record_completed(state, tag, result)}

      %AwaitSuspend{request: request, resume: resume} ->
        # Waiting on async
        case State.add_suspension(state, request.id, request, resume) do
          {:ready, state} ->
            # Early completions satisfied immediately
            state = put_in(state.completed[request.id], {:tag, tag})
            {:ok, state}

          {:suspended, state} ->
            state = put_in(state.completed[request.id], {:tag, tag})
            {:ok, start_timers(state, request)}
        end

      %Suspend{} = _suspend ->
        # External yield on first run - record as pending external
        # This is a bit unusual - typically computations start with async work
        Logger.warning("Computation yielded externally on spawn - not fully supported yet")
        {:ok, State.record_completed(state, tag, {:error, :external_yield_on_spawn})}

      {:error, reason} ->
        handle_spawn_error(state, tag, reason)
    end
  end

  # Handle error during spawn based on :on_error option
  defp handle_spawn_error(state, tag, reason) do
    case Keyword.get(state.opts, :on_error, :log_and_continue) do
      :log_and_continue ->
        Logger.error("Computation #{inspect(tag)} failed on spawn: #{inspect(reason)}")
        {:ok, State.record_completed(state, tag, {:error, reason})}

      :stop ->
        {:error, reason}

      {:callback, fun} ->
        case fun.(reason, state) do
          {:continue, new_state} -> {:ok, new_state}
          {:stop, reason} -> {:error, reason}
        end
    end
  end

  # Run a computation until it returns a value or suspends
  defp run_until_suspend(comp) do
    env = Env.new()

    try do
      case Comp.call(comp, env, fn v, _e -> {:done, v} end) do
        {:done, result} ->
          {:done, result}

        # Suspensions return {suspend, env} tuple
        {%AwaitSuspend{} = suspend, _env} ->
          suspend

        {%Suspend{} = suspend, _env} ->
          suspend

        # Handle Throw sentinels
        {%Comp.Throw{} = throw, _env} ->
          {:error, {:throw, throw.error}}

        # Direct sentinel (shouldn't normally happen but handle it)
        %AwaitSuspend{} = suspend ->
          suspend

        %Suspend{} = suspend ->
          suspend

        other ->
          # Handle other sentinel types
          if is_tuple(other) and tuple_size(other) == 2 do
            {value, _env} = other

            if Comp.ISentinel.impl_for(value) do
              value
            else
              {:done, value}
            end
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

        # Suspensions return {suspend, env} tuple
        {%AwaitSuspend{} = suspend, _env} ->
          suspend

        {%Suspend{} = suspend, _env} ->
          suspend

        # Handle Throw sentinels
        {%Comp.Throw{} = throw, _env} ->
          {:error, {:throw, throw.error}}

        # Plain {value, env} tuple from continuation
        {result, %Env{}} ->
          {:done, result}

        # Direct sentinel (shouldn't normally happen)
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

        case State.add_suspension(state, request.id, request, resume) do
          {:ready, state} ->
            # Early completions satisfied immediately
            run_loop(state)

          {:suspended, state} ->
            state = start_timers(state, request)
            run_loop(state)
        end

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
        state = record_with_tag_resolution(state, request_id, {:error, reason})
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
