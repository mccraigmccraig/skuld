defmodule Skuld.Effects.Async.Scheduler do
  @moduledoc """
  Cooperative scheduler for running multiple Async computations.

  The scheduler runs computations until they yield `%AwaitSuspend{}`,
  tracks their await requests, and resumes them when completions arrive.

  ## Single Computation

      comp do
        h <- Async.async(work())
        Async.await(h)
      end
      |> Async.with_handler()
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
  alias Skuld.Effects.Async.AwaitRequest.TimerTarget
  alias Skuld.Effects.Async.AwaitSuspend

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
      {:done, result, env} ->
        # Extract any fibers and run them if needed
        state = extract_and_enqueue_fibers(state, env)

        if State.active?(state) do
          # Fibers were spawned - need to run them
          state = %{state | completed: Map.put(state.completed, tag, result)}
          run_one_loop(state, tag)
        else
          {:done, result}
        end

      {:await_suspend, %AwaitSuspend{request: request, resume: resume}, env} ->
        # Extract fibers, track and run loop
        state = extract_and_enqueue_fibers(state, env)

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

      {:suspend, %Suspend{resume: resume} = suspend, _env} ->
        # External yield - return to caller with resume function
        resume_fn = fn value ->
          resumed_result = resume.(value)
          # Resume returns {result, env} or a suspension
          handle_resumed(resumed_result, opts)
        end

        {:suspended, suspend, resume_fn}

      {:error, reason, _env} ->
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
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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

      {:ok, {:fiber, fiber_id}, state} ->
        # Run a fiber
        run_fiber(state, fiber_id)

      {:ok, {request_id, resume, results}, state} ->
        case run_resume(resume, results) do
          {:done, result, env} ->
            # Extract any fibers spawned
            state = extract_and_enqueue_fibers(state, env)

            # Check if this is our computation (via the pending marker) or a fiber
            state =
              case Map.get(state.completed, request_id) do
                {:pending, ^tag} ->
                  # This is our computation - store the actual result
                  %{state | completed: Map.put(state.completed, tag, result)}

                {:fiber_tag, fiber_id} ->
                  # This was a fiber - record fiber result to wake waiters
                  case State.record_fiber_result(state, fiber_id, {:ok, result}) do
                    {:woke, _wake_request_id, _wake_result, state} -> state
                    {:waiting, state} -> state
                  end

                _ ->
                  State.record_completed(state, request_id, result)
              end

            {:continue, state}

          {:await_suspend, %AwaitSuspend{request: request, resume: new_resume}, env} ->
            # Extract any fibers spawned
            state = extract_and_enqueue_fibers(state, env)

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

          {:suspend, %Suspend{} = suspend, _env} ->
            {:suspended, suspend, state}

          {:error, reason, env} ->
            # Extract any fibers spawned before error
            state = extract_and_enqueue_fibers(state, env)
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
  @spec step(State.t()) ::
          {:continue, State.t()} | {:idle, State.t()} | {:done, State.t()} | {:error, term()}
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
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp run_ready(state) do
    case State.dequeue_one(state) do
      {:empty, state} ->
        # Nothing in run queue
        if State.active?(state) do
          {:receive, state}
        else
          {:done, state}
        end

      {:ok, {:fiber, fiber_id}, state} ->
        # Run a fiber
        run_fiber(state, fiber_id)

      {:ok, {request_id, resume, results}, state} ->
        case run_resume(resume, results) do
          {:done, result, env} ->
            # Extract any fibers spawned
            state = extract_and_enqueue_fibers(state, env)

            # Check if this was a fiber - if so, record fiber result to wake waiters
            state =
              case Map.get(state.completed, request_id) do
                {:fiber_tag, fiber_id} ->
                  # This was a fiber - record fiber result to wake waiters
                  case State.record_fiber_result(state, fiber_id, {:ok, result}) do
                    {:woke, _wake_request_id, _wake_result, state} -> state
                    {:waiting, state} -> state
                  end

                _ ->
                  record_with_tag_resolution(state, request_id, result)
              end

            {:continue, state}

          {:await_suspend, %AwaitSuspend{request: request, resume: new_resume}, env} ->
            # Suspended again on new await - extract fibers, transfer tag association
            state = extract_and_enqueue_fibers(state, env)
            state = transfer_tag_association(state, request_id, request.id)

            case State.add_suspension(state, request.id, request, new_resume) do
              {:ready, state} ->
                # Early completions satisfied immediately
                {:continue, state}

              {:suspended, state} ->
                state = start_timers(state, request)
                {:continue, state}
            end

          {:suspend, %Suspend{} = suspend, _env} ->
            # External yield - pause this computation
            {:suspended, suspend, state}

          {:error, reason, env} ->
            # Extract any fibers before handling error
            state = extract_and_enqueue_fibers(state, env)
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

      {:fiber_tag, fiber_id} ->
        # This was a fiber - record the fiber result
        state
        |> update_in([Access.key(:completed)], &Map.delete(&1, request_id))
        |> then(fn s ->
          case State.record_fiber_result(s, fiber_id, {:ok, result}) do
            {:woke, _req_id, _wake_result, new_state} -> new_state
            {:waiting, new_state} -> new_state
          end
        end)

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

      {:fiber_tag, fiber_id} ->
        state
        |> update_in([Access.key(:completed)], &Map.delete(&1, old_request_id))
        |> put_in([Access.key(:completed), new_request_id], {:fiber_tag, fiber_id})

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
      {:done, result, env} ->
        # Completed immediately - extract any fibers spawned
        state = extract_and_enqueue_fibers(state, env)
        {:ok, State.record_completed(state, tag, result)}

      {:await_suspend, %AwaitSuspend{request: request, resume: resume}, env} ->
        # Waiting on async - extract fibers then track suspension
        state = extract_and_enqueue_fibers(state, env)

        case State.add_suspension(state, request.id, request, resume) do
          {:ready, state} ->
            # Early completions satisfied immediately
            state = put_in(state.completed[request.id], {:tag, tag})
            {:ok, state}

          {:suspended, state} ->
            state = put_in(state.completed[request.id], {:tag, tag})
            {:ok, start_timers(state, request)}
        end

      {:suspend, %Suspend{}, _env} ->
        # External yield on first run - record as pending external
        # This is a bit unusual - typically computations start with async work
        Logger.warning("Computation yielded externally on spawn - not fully supported yet")
        {:ok, State.record_completed(state, tag, {:error, :external_yield_on_spawn})}

      {:error, reason, env} ->
        # Extract any fibers that were spawned before the error
        state = extract_and_enqueue_fibers(state, env)
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

  # Run a computation until it returns a value or suspends.
  # Returns {status, result_or_suspend, env} to allow fiber extraction.
  defp run_until_suspend(comp) do
    env = Env.new()
    run_until_suspend(comp, env)
  end

  # Run a computation with a given env until it returns a value or suspends.
  # Used for running fibers which inherit their parent's env.
  # Note: uses implicit try - rescue/catch at function level
  defp run_until_suspend(comp, env) do
    case Comp.call(comp, env, &Comp.identity_k/2) do
      # Suspensions return {suspend, env} tuple
      {%AwaitSuspend{} = suspend, suspend_env} ->
        {:await_suspend, suspend, suspend_env}

      {%Suspend{} = suspend, suspend_env} ->
        {:suspend, suspend, suspend_env}

      # Handle Throw sentinels
      {%Comp.Throw{} = throw, throw_env} ->
        {:error, {:throw, throw.error}, throw_env}

      # Handle Cancelled sentinels
      {%Comp.Cancelled{} = cancelled, cancelled_env} ->
        {:error, {:cancelled, cancelled.reason}, cancelled_env}

      # Regular {value, env} tuples - normal completion
      {value, %Env{} = final_env} ->
        {:done, value, final_env}
    end
  rescue
    e ->
      {:error, {:exception, e, __STACKTRACE__}, env}
  catch
    :throw, reason ->
      {:error, {:throw, reason}, env}

    :exit, reason ->
      {:error, {:exit, reason}, env}
  end

  # Resume a suspended computation with results.
  # Returns {status, result_or_suspend, env} to allow fiber extraction.
  # Note: uses implicit try - rescue/catch at function level
  defp run_resume(resume, results) do
    case resume.(results) do
      # Suspensions return {suspend, env} tuple
      {%AwaitSuspend{} = suspend, suspend_env} ->
        {:await_suspend, suspend, suspend_env}

      {%Suspend{} = suspend, suspend_env} ->
        {:suspend, suspend, suspend_env}

      # Handle Throw sentinels
      {%Comp.Throw{} = throw, throw_env} ->
        {:error, {:throw, throw.error}, throw_env}

      # Handle Cancelled sentinels
      {%Comp.Cancelled{} = cancelled, cancelled_env} ->
        {:error, {:cancelled, cancelled.reason}, cancelled_env}

      # Regular {value, env} tuples - normal completion
      {value, %Env{} = final_env} ->
        {:done, value, final_env}
    end
  rescue
    e ->
      # No env available on exception
      {:error, {:exception, e, __STACKTRACE__}, nil}
  catch
    :throw, reason ->
      {:error, {:throw, reason}, nil}

    :exit, reason ->
      {:error, {:exit, reason}, nil}
  end

  # Handle the result of resuming a suspended computation.
  # This handles raw results from calling resume.(value) directly.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp handle_resumed(result, opts) do
    case result do
      {value, %Env{} = env} ->
        # Normal completion - extract any fibers and run them
        state = State.new(opts)
        state = extract_and_enqueue_fibers(state, env)

        if State.active?(state) do
          state = State.record_completed(state, :main, value)
          run_loop(state)
        else
          {:done, value}
        end

      {%AwaitSuspend{request: request, resume: resume}, env} ->
        # Suspended on await - extract fibers
        state = State.new(opts)
        state = extract_and_enqueue_fibers(state, env)

        case State.add_suspension(state, request.id, request, resume) do
          {:ready, state} ->
            # Early completions satisfied immediately
            run_loop(state)

          {:suspended, state} ->
            state = start_timers(state, request)
            run_loop(state)
        end

      {%Suspend{resume: resume} = suspend, _env} ->
        # Another external yield
        resume_fn = fn value ->
          resumed_result = resume.(value)
          handle_resumed(resumed_result, opts)
        end

        {:suspended, suspend, resume_fn}

      {%Comp.Throw{error: error}, _env} ->
        {:error, {:throw, error}}

      {%Comp.Cancelled{reason: reason}, _env} ->
        {:error, {:cancelled, reason}}

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

  #############################################################################
  ## Fiber Helpers
  #############################################################################

  @pending_fibers_key {Skuld.Effects.Async, :pending_fibers}

  # Extract pending fibers from env and add them to the scheduler state.
  # The fibers are stored in env state by the Async.fiber/1 handler.
  # Returns the updated state with fibers added to run queue.
  defp extract_and_enqueue_fibers(state, nil), do: state

  defp extract_and_enqueue_fibers(state, env) do
    pending = Env.get_state(env, @pending_fibers_key, [])

    # Add each fiber to the scheduler
    # Fibers are stored as {fiber_id, comp, boundary_id}
    # Skip fibers that have already been added or completed (can happen when
    # a resumed computation's env still has the fiber in pending_fibers)
    Enum.reduce(pending, state, fn {fiber_id, comp, boundary_id}, acc ->
      cond do
        # Already running/pending - skip
        Map.has_key?(acc.fibers, fiber_id) -> acc
        # Already completed - skip
        Map.has_key?(acc.fiber_results, fiber_id) -> acc
        # New fiber - add it
        true -> State.add_fiber(acc, fiber_id, comp, boundary_id, env)
      end
    end)
  end

  # Run a fiber from the run queue
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp run_fiber(state, fiber_id) do
    case State.get_fiber(state, fiber_id) do
      nil ->
        # Fiber was cancelled or already completed
        {:continue, state}

      %{comp: comp, env: env} ->
        # Clear pending fibers from env before running (they've been extracted)
        env = Env.put_state(env, @pending_fibers_key, [])

        case run_until_suspend(comp, env) do
          {:done, result, final_env} ->
            # Fiber completed - extract any fibers it spawned, then record result
            state = extract_and_enqueue_fibers(state, final_env)

            case State.record_fiber_result(state, fiber_id, {:ok, result}) do
              {:woke, _request_id, _wake_result, state} -> {:continue, state}
              {:waiting, state} -> {:continue, state}
            end

          {:await_suspend, suspend, suspend_env} ->
            # Fiber suspended on await - extract fibers, track suspension
            state = extract_and_enqueue_fibers(state, suspend_env)
            state = State.remove_fiber(state, fiber_id)

            # Track the fiber's suspension like a regular computation
            # Use fiber_id as the tag for result tracking
            request = suspend.request

            case State.add_suspension(state, request.id, request, suspend.resume) do
              {:ready, state} ->
                # Early completions satisfied immediately
                state = put_in(state.completed[request.id], {:fiber_tag, fiber_id})
                {:continue, state}

              {:suspended, state} ->
                state = put_in(state.completed[request.id], {:fiber_tag, fiber_id})
                state = start_timers(state, request)
                {:continue, state}
            end

          {:suspend, _suspend, _suspend_env} ->
            # External suspend from a fiber - not fully supported
            Logger.warning("Fiber yielded externally - not fully supported")

            case State.record_fiber_result(state, fiber_id, {:error, :external_yield}) do
              {:woke, _request_id, _wake_result, state} -> {:continue, state}
              {:waiting, state} -> {:continue, state}
            end

          {:error, reason, error_env} ->
            # Fiber failed - extract any fibers it spawned, then record error
            state = extract_and_enqueue_fibers(state, error_env)

            case State.record_fiber_result(state, fiber_id, {:error, reason}) do
              {:woke, _request_id, _wake_result, state} -> {:continue, state}
              {:waiting, state} -> {:continue, state}
            end
        end
    end
  end
end
