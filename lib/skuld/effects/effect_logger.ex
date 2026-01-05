defmodule Skuld.Effects.EffectLogger do
  @moduledoc """
  Effect logging, replay, and resume for Skuld computations.

  EffectLogger provides three main capabilities:

  1. **Logging** - Capture all effect calls as serializable log entries
  2. **Replay** - Re-run computations using logged results instead of real effects
  3. **Resume** - Continue suspended computations from persisted logs

  ## Use Case 1: Effect Logging / Tracing

  Wrap a computation to capture all effect calls:

      {{result, log}, _env} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Reader.with_handler(:config)
        |> Comp.run()

      # log is a list of LogEntry structs (Completed, Thrown, Started, etc.)

  Logs can be serialized to JSON for persistence:

      json = LogEntry.json_encode_log(log)
      {:ok, log} = LogEntry.json_decode_log(json)

  **Note**: EffectLogger must be innermost (first in pipe chain) to see
  handlers installed by outer `with_handler` calls.

  ## Use Case 2: Retry After Failure

  When a computation fails, use `retry_from_failure/3` to re-run it:

      # Original run fails
      {{%Comp.Throw{}, log}, _env} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> ExternalService.with_handler()
        |> Comp.run()

      # Retry - effects before failure are replayed, then execution continues
      {result, _env} =
        my_comp
        |> EffectLogger.retry_from_failure(log)
        |> State.with_handler(0)
        |> ExternalService.with_handler()
        |> Comp.run()

  ## Use Case 3: Resume After Suspend

  Computations using `Yield` can suspend and be resumed later.

  ### Hot Resume (in-memory continuation)

  When you have a live `%Comp.Suspend{}` result, call the continuation directly:

      # Run computation - suspends at Yield
      {%Comp.Suspend{value: yielded, resume: resume}, _env} =
        my_comp
        |> EffectLogger.with_logging()
        |> Yield.with_handler()
        |> State.with_handler(0)
        |> Comp.run()

      # Do something with yielded value, get user input, etc.
      user_input = get_user_response(yielded)

      # Hot resume - call continuation directly
      {{result, log}, _env} = resume.(user_input)

  ### Cold Resume (from persisted log)

  When the log has been persisted and you no longer have the live continuation,
  use `resume_from_log/4`:

      # Load log from database (ends with Suspended entry)
      {:ok, cold_log} = LogEntry.json_decode_log(json_from_db)

      # Cold resume - replays effects, injects resume value, continues execution
      {result, _env} =
        my_comp
        |> EffectLogger.resume_from_log(cold_log, user_input)
        |> Yield.with_handler()
        |> State.with_handler(0)
        |> Comp.run()

  ## Log Entry Types

  All entries are structs from `Skuld.Effects.EffectLogger.LogEntry`:

  | Entry | Description |
  |-------|-------------|
  | `Completed` | Simple effect completed synchronously |
  | `Thrown` | Effect threw an error (terminal) |
  | `Started` | Suspending effect began (for Yield, etc.) |
  | `Suspended` | Effect yielded/suspended with a value |
  | `Resumed` | Suspended effect was resumed with input |
  | `Finished` | Suspending effect completed after resume(s) |

  ## Hot vs Cold Logs

  - **Hot log**: In-memory structs, may include live continuations in Suspend results
  - **Cold log**: Deserialized from JSON, no live continuations available

  When to use each:
  - Use **hot resume** (`resume.(input)`) when the process is still alive
  - Use **cold resume** (`resume_from_log/4`) after persistence/restart

  ## Limitations

  After JSON round-trip, atoms become strings:
  - `:ok` → `"ok"`
  - `%{foo: 1}` → `%{"foo" => 1}`

  This can cause replay divergence if effect args contain atoms. Use string
  values for data that needs to survive JSON serialization, or use hot replay
  when possible.

  See `Skuld.Effects.EffectLogger.LogEntry` for full documentation.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.ISentinel
  alias Skuld.Comp.Types

  alias __MODULE__.LogEntry
  alias LogEntry.Completed
  alias LogEntry.Finished
  alias LogEntry.Resumed
  alias LogEntry.Started
  alias LogEntry.Suspended
  alias LogEntry.Thrown

  @log_key {__MODULE__, :log}
  @log_pdict_key {__MODULE__, :log_pdict}
  @pending_finish_key {__MODULE__, :pending_finish}
  @replay_key {__MODULE__, :replay}

  #############################################################################
  ## Logging
  #############################################################################

  @doc """
  Wrap a computation with effect logging.

  Returns a computation that, when run, logs all effect calls and returns
  the result transformed by the `:output` function.

  Must be applied innermost (first in the pipe chain) so it runs after
  outer `with_handler` calls have installed their handlers.

  ## Options

  - `:output` - function `(result, log) -> output` to transform the result.
    Default: `fn result, log -> {result, log} end`
  - `:effects` - list of effect signatures to log (default: all handlers in evidence)
  - `:timestamp_fn` - function to generate timestamps (default: `DateTime.utc_now/0`)
  - `:id_fn` - function to generate unique IDs (default: `make_ref/0`)

  ## Examples

      # Default: returns {result, log}
      {result_with_log, _env} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run(Env.new())

      {result, log} = result_with_log

      # Custom output: just the result, discard log
      result =
        my_comp
        |> EffectLogger.with_logging(output: fn result, _log -> result end)
        |> State.with_handler(0)
        |> Comp.run!()

      # Custom output: log only
      log =
        my_comp
        |> EffectLogger.with_logging(output: fn _result, log -> log end)
        |> State.with_handler(0)
        |> Comp.run!()
  """
  @spec with_logging(Types.computation(), keyword()) :: Types.computation()
  def with_logging(comp, opts \\ []) do
    output_fn = Keyword.get(opts, :output, fn result, log -> {result, log} end)
    timestamp_fn = Keyword.get(opts, :timestamp_fn, &DateTime.utc_now/0)
    id_fn = Keyword.get(opts, :id_fn, &generate_uuid/0)
    effects_opt = Keyword.get(opts, :effects)

    comp
    |> Comp.scoped(fn env ->
      effects_to_log = effects_opt || Map.keys(env.evidence)

      # Setup: initialize log in process dictionary (survives leave_scope)
      # and mark env so we know logging is active
      Process.put(@log_pdict_key, [])
      env_with_log = Env.put_state(env, @log_key, true)

      logged_env =
        Enum.reduce(effects_to_log, env_with_log, fn sig, acc_env ->
          case acc_env.evidence[sig] do
            nil ->
              # No handler for this effect - skip
              acc_env

            handler ->
              logged_handler = make_logging_handler(sig, handler, timestamp_fn, id_fn)
              Env.with_handler(acc_env, sig, logged_handler)
          end
        end)

      # Finally: extract log and transform result using output function
      finally_k = fn result, final_env ->
        # Check for pending Finished entries from resumed effects
        pending_finish = Process.get(@pending_finish_key, [])
        Process.delete(@pending_finish_key)

        # Add Finished entries for any pending resumed effects (only if not a sentinel)
        unless ISentinel.sentinel?(result) do
          Enum.each(pending_finish, fn {pending_log_id, pending_timestamp_fn} ->
            finished_entry = %Finished{
              id: pending_log_id,
              result: result,
              timestamp: pending_timestamp_fn.()
            }

            append_log_entry(finished_entry)
          end)
        end

        log = Process.get(@log_pdict_key, [])
        Process.delete(@log_pdict_key)
        cleaned_env = clean_log_state(final_env)
        {output_fn.(result, Enum.reverse(log)), cleaned_env}
      end

      {logged_env, finally_k}
    end)
  end

  defp make_logging_handler(sig, original_handler, timestamp_fn, id_fn) do
    fn args, env, k ->
      log_id = id_fn.()
      started_at = timestamp_fn.()

      # Track whether this effect was logged via k (normal completion)
      flag_key = {:effect_logged, log_id}
      Process.put(flag_key, false)

      # Wrap k to capture the result when the handler calls it
      logging_k = fn value, env_after_effect ->
        # Mark that we logged this effect
        Process.put(flag_key, true)

        # Check if we're resuming this effect (timestamp_fn stored by logged_resume)
        case Process.delete({__MODULE__, :resuming, log_id}) do
          nil ->
            # Normal effect completion - log Completed and continue
            entry = %Completed{
              id: log_id,
              effect: sig,
              args: args,
              result: value,
              timestamp: started_at
            }

            append_log(env_after_effect, entry)
            k.(value, env_after_effect)

          timestamp_fn ->
            # We're resuming - register a pending Finished entry that finally_k will complete
            pending = Process.get(@pending_finish_key, [])
            Process.put(@pending_finish_key, [{log_id, timestamp_fn} | pending])

            # Continue with the computation
            k.(value, env_after_effect)
        end
      end

      # Call original handler with logging k
      {result, result_env} = Comp.call_handler(original_handler, args, env, logging_k)

      # Clean up flag
      was_logged = Process.delete(flag_key)

      # Handle outcomes that don't go through k (sentinels)
      if ISentinel.sentinel?(result) do
        case ISentinel.get_resume(result) do
          nil ->
            # Terminal sentinel (Throw, etc.) - only log if this handler threw
            if was_logged do
              # Sentinel from nested effect - just pass through
              {result, result_env}
            else
              # This handler produced the sentinel - log it
              %{error: error} = ISentinel.serializable_payload(result)

              entry = %Thrown{
                id: log_id,
                effect: sig,
                args: args,
                error: error,
                timestamp: started_at
              }

              {result, append_log(result_env, entry)}
            end

          inner_resume ->
            # Resumable sentinel (Suspend, etc.)
            if was_logged do
              # Sentinel from nested effect - just pass through
              {result, result_env}
            else
              # This handler produced the sentinel - log lifecycle
              start_entry = %Started{
                id: log_id,
                effect: sig,
                args: args,
                timestamp: started_at
              }

              %{yielded: yielded} = ISentinel.serializable_payload(result)

              suspend_entry = %Suspended{
                id: log_id,
                yielded: yielded,
                timestamp: timestamp_fn.()
              }

              logged_env =
                result_env
                |> append_log(start_entry)
                |> append_log(suspend_entry)

              # Wrap the resume to log when it's called
              logged_resume = make_logged_resume(inner_resume, log_id, timestamp_fn)
              new_sentinel = ISentinel.with_resume(result, logged_resume)

              {new_sentinel, logged_env}
            end
        end
      else
        # Normal value - logging already happened in logging_k
        {result, result_env}
      end
    end
  end

  # Create a logged resume function that wraps the original
  defp make_logged_resume(inner_resume, log_id, timestamp_fn) do
    fn input ->
      # Log Resumed entry BEFORE calling inner_resume (so it's captured before finally_k)
      resume_entry = %Resumed{
        id: log_id,
        input: input,
        timestamp: timestamp_fn.()
      }

      append_log_entry(resume_entry)

      # Set flag so logging_k knows we're resuming and should add Finished instead of Completed
      Process.put({__MODULE__, :resuming, log_id}, timestamp_fn)

      # Call original resume (arity-1)
      {res_result, res_env} = inner_resume.(input)

      # If the result is a sentinel (Suspend from nested effect, or Throw),
      # just pass it through. The nested effect's own logging handles its lifecycle.
      # Our Finished entry will be logged when we eventually complete (via pending_finish).
      {res_result, res_env}
    end
  end

  # Append a log entry directly to process dictionary
  defp append_log_entry(entry) do
    log = Process.get(@log_pdict_key, [])
    Process.put(@log_pdict_key, [entry | log])
  end

  defp append_log(env, entry) do
    log = Process.get(@log_pdict_key, [])
    Process.put(@log_pdict_key, [entry | log])
    env
  end

  defp clean_log_state(env) do
    %{env | state: Map.delete(env.state, @log_key)}
  end

  #############################################################################
  ## Replay
  #############################################################################

  @doc """
  Wrap a computation for replay mode using a previously captured log.

  Effects are short-circuited with logged responses instead of executing
  real handlers. Pure computation segments run normally.

  Must be applied innermost (first in the pipe chain) so it runs after
  outer `with_handler` calls have installed their handlers.

  ## Options

  - `:on_missing` - what to do when an effect isn't in the log:
    - `:error` (default) - raise an error
    - `:execute` - fall through to real handler

  ## Example

      {result, _env} =
        my_comp
        |> EffectLogger.replay(log)
        |> State.with_handler(0)
        |> Comp.run(Env.new())
  """
  @spec replay(Types.computation(), [LogEntry.t()], keyword()) :: Types.computation()
  def replay(comp, log, opts \\ []) do
    fn env, k ->
      on_missing = Keyword.get(opts, :on_missing, :error)

      # Convert log to a queue for sequential consumption
      log_queue = :queue.from_list(log)
      env_with_replay = Env.put_state(env, @replay_key, log_queue)

      # Interpose replay handlers on all logged effects
      # Only Completed, Thrown, and Started entries have the :effect field
      logged_effects =
        log
        |> Enum.filter(&Map.has_key?(&1, :effect))
        |> Enum.map(& &1.effect)
        |> Enum.uniq()

      replay_env =
        Enum.reduce(logged_effects, env_with_replay, fn sig, acc_env ->
          original_handler = acc_env.evidence[sig]
          replay_handler = make_replay_handler(sig, original_handler, on_missing)
          Env.with_handler(acc_env, sig, replay_handler)
        end)

      # Run inner computation with replay handlers
      Comp.call(comp, replay_env, fn result, final_env ->
        cleaned_env = clean_replay_state(final_env)
        k.(result, cleaned_env)
      end)
    end
  end

  defp make_replay_handler(sig, original_handler, on_missing) do
    fn args, env, k ->
      log_queue = Env.get_state(env, @replay_key)

      case :queue.out(log_queue) do
        {{:value, entry}, rest_queue} ->
          # Check if this entry matches the current effect
          if matches_effect?(entry, sig, args) do
            env_updated = Env.put_state(env, @replay_key, rest_queue)

            case entry do
              %Completed{result: result} ->
                # Simple effect - return logged result
                k.(result, env_updated)

              %Started{} ->
                # Suspending effect - need to handle the full lifecycle
                replay_suspending_effect(entry, env_updated, k)

              %Thrown{error: error} ->
                # Effect threw - return Throw sentinel
                {%Comp.Throw{error: error}, env_updated}
            end
          else
            # Log mismatch - divergence detected
            handle_missing(on_missing, sig, args, env, k, original_handler)
          end

        {:empty, _} ->
          # Log exhausted - new effect not in log
          handle_missing(on_missing, sig, args, env, k, original_handler)
      end
    end
  end

  defp matches_effect?(%Completed{effect: effect, args: logged_args}, sig, args) do
    effect == sig && logged_args == args
  end

  defp matches_effect?(%Thrown{effect: effect, args: logged_args}, sig, args) do
    effect == sig && logged_args == args
  end

  defp matches_effect?(%Started{effect: effect, args: logged_args}, sig, args) do
    effect == sig && logged_args == args
  end

  defp matches_effect?(_, _, _), do: false

  defp replay_suspending_effect(%Started{id: log_id}, env, k) do
    # Find the corresponding suspended/resumed/completed entries
    log_queue = Env.get_state(env, @replay_key)

    # Consume entries until we find completion or another suspension
    case consume_until_completion(log_queue, log_id) do
      {:completed, result, rest_queue} ->
        env_updated = Env.put_state(env, @replay_key, rest_queue)
        k.(result, env_updated)

      {:suspended, _yielded, input, rest_queue} ->
        # The effect suspended and was resumed with input
        env_updated = Env.put_state(env, @replay_key, rest_queue)
        # Continue as if we got that input
        k.(input, env_updated)

      {:thrown, error, rest_queue} ->
        env_updated = Env.put_state(env, @replay_key, rest_queue)
        {%Comp.Throw{error: error}, env_updated}
    end
  end

  # Consume log entries to find how a suspending effect completed.
  # IMPORTANT: Entries for OTHER effects may be interleaved (nested effects).
  # We extract only the entries matching log_id, leaving others in place.
  defp consume_until_completion(queue, log_id) do
    # Convert to list for easier manipulation
    entries = :queue.to_list(queue)

    # Find and extract entries for this effect ID
    {our_entries, other_entries} =
      Enum.split_with(entries, fn entry -> Map.get(entry, :id) == log_id end)

    # Reconstruct queue without our entries
    rest_queue = :queue.from_list(other_entries)

    # Process our entries in order
    process_effect_entries(our_entries, log_id, rest_queue)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp process_effect_entries(entries, _log_id, rest_queue) do
    # Entries should be in order: [Suspended, Resumed, Finished] or [Suspended] (incomplete)
    # or for simple effects that somehow ended up here: [Finished]
    case entries do
      [%Finished{result: result} | _] ->
        # Direct completion without suspend
        {:completed, result, rest_queue}

      [%Suspended{}, %Resumed{input: input} | rest] ->
        # Suspended and resumed - look for completion
        case Enum.find(rest, &match?(%Finished{}, &1)) do
          %Finished{} ->
            {:suspended, nil, input, rest_queue}

          nil ->
            # Check for re-suspension
            case Enum.find(rest, &match?(%Suspended{}, &1)) do
              %Suspended{} ->
                # Re-suspended - for now treat as incomplete
                {:suspended, nil, input, rest_queue}

              nil ->
                # No finished, no re-suspend - incomplete
                {:suspended, nil, input, rest_queue}
            end
        end

      [%Suspended{}] ->
        # Suspended but never resumed - incomplete log, cannot replay
        {:thrown, :replay_log_incomplete, rest_queue}

      [%Thrown{error: error} | _] ->
        {:thrown, error, rest_queue}

      [] ->
        # No entries for this effect - shouldn't happen
        {:thrown, :replay_log_incomplete, rest_queue}

      _ ->
        # Unexpected entry order
        {:thrown, :replay_log_incomplete, rest_queue}
    end
  end

  # No longer needed - functionality merged into consume_until_completion
  # defp consume_until_completion_after_resume is replaced by process_effect_entries

  defp handle_missing(:error, sig, args, _env, _k, _handler) do
    raise "Replay divergence: effect #{inspect(sig)} with args #{inspect(args)} not found in log"
  end

  defp handle_missing(:execute, _sig, args, env, k, handler) do
    # Fall through to real handler
    Comp.call_handler(handler, args, env, k)
  end

  defp clean_replay_state(env) do
    %{env | state: Map.delete(env.state, @replay_key)}
  end

  #############################################################################
  ## Retry from Failure
  #############################################################################

  @doc """
  Retry a computation from a point of failure using a previously captured log.

  Given a log that contains a `Thrown` entry, this function:
  1. Truncates the log before the `Thrown` entry
  2. Replays effects from the truncated log (short-circuiting with logged results)
  3. Continues with real effect execution from the failure point

  This is useful for retrying after transient failures - effects that succeeded
  before the failure are replayed (not re-executed), and only the failed effect
  and subsequent ones are executed fresh.

  Works with both:
  - **Hot logs**: In-memory `LogEntry` structs
  - **Cold logs**: Deserialized from JSON via `LogEntry.json_decode_log/1`

  ## Options

  Same as `replay/3`, except `:on_missing` defaults to `:execute` (since the
  whole point is to continue execution after the logged effects).

  ## Example

      # Original computation that failed
      {{%Comp.Throw{}, log}, _env} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> ExternalService.with_handler()
        |> Comp.run()

      # Retry from failure - effects before the throw are replayed,
      # the failed effect and beyond are re-executed
      {result, _env} =
        my_comp
        |> EffectLogger.retry_from_failure(log)
        |> State.with_handler(0)
        |> ExternalService.with_handler()
        |> Comp.run()

      # For cold logs (e.g., loaded from database)
      {:ok, cold_log} = LogEntry.json_decode_log(json_from_db)
      {result, _env} =
        my_comp
        |> EffectLogger.retry_from_failure(cold_log)
        |> State.with_handler(0)
        |> ExternalService.with_handler()
        |> Comp.run()
  """
  @spec retry_from_failure(Types.computation(), [LogEntry.t()], keyword()) :: Types.computation()
  def retry_from_failure(comp, log, opts \\ []) do
    # Find and remove the Thrown entry and everything after it
    log_before_failure =
      Enum.take_while(log, fn
        %Thrown{} -> false
        _ -> true
      end)

    # Default to :execute for on_missing since we want to continue execution
    opts = Keyword.put_new(opts, :on_missing, :execute)

    replay(comp, log_before_failure, opts)
  end

  #############################################################################
  ## Cold Resume
  #############################################################################

  @doc """
  Resume a suspended computation from a cold (deserialized) log.

  Given a log that ends with a `Suspended` entry (no live continuation available),
  this function:
  1. Replays all effects up to and including the suspension point
  2. Injects the provided `resume_value` as if the user had called `resume.(value)`
  3. Continues with real effect execution from that point

  This is useful for resuming computations that were suspended, had their log
  persisted (e.g., to a database), and need to be resumed later - potentially
  in a different process or after a restart.

  Works with both:
  - **Hot logs**: In-memory `LogEntry` structs (though hot logs have live
    continuations, so you'd normally just call `resume.(value)` directly)
  - **Cold logs**: Deserialized from JSON via `LogEntry.json_decode_log/1`

  ## Options

  Same as `replay/3`, except `:on_missing` defaults to `:execute` (since
  effects after the suspension point should execute normally).

  ## Example

      # Original computation suspended
      {%Comp.Suspend{value: yielded}, _env} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Yield.with_handler()
        |> Comp.run()

      # ... time passes, log is persisted ...

      # Later: resume from cold log
      {:ok, cold_log} = LogEntry.json_decode_log(json_from_db)
      {result, _env} =
        my_comp
        |> EffectLogger.resume_from_log(cold_log, user_provided_input)
        |> State.with_handler(0)
        |> Yield.with_handler()
        |> Comp.run()
  """
  @spec resume_from_log(Types.computation(), [LogEntry.t()], term(), keyword()) ::
          Types.computation()
  def resume_from_log(comp, log, resume_value, opts \\ []) do
    # Find the last Suspended entry and add a synthetic Resumed entry
    log_with_resume = inject_resume_entry(log, resume_value)

    # Default to :execute for on_missing since effects after suspend should run
    opts = Keyword.put_new(opts, :on_missing, :execute)

    replay(comp, log_with_resume, opts)
  end

  defp inject_resume_entry(log, resume_value) do
    # Find the last Suspended entry (the one we're resuming from)
    case Enum.reverse(log) do
      [%Suspended{id: suspend_id} = suspended | rest] ->
        # Add a Resumed entry after the Suspended entry
        resumed = %Resumed{
          id: suspend_id,
          input: resume_value,
          timestamp: DateTime.utc_now()
        }

        # Reconstruct log with Resumed entry inserted after Suspended
        Enum.reverse([resumed, suspended | rest])

      _ ->
        # Log doesn't end with Suspended - just return as-is
        # (replay will handle any errors)
        log
    end
  end

  @doc false
  # Generate a random UUID v4 string
  def generate_uuid do
    UUID.uuid4()
  end
end
