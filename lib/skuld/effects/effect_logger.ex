defmodule Skuld.Effects.EffectLogger do
  @moduledoc """
  Effect logging for replay, resume, and rerun capabilities.

  EffectLogger captures effect invocations in a flat log, enabling:

  - **Replay**: Short-circuit completed effects with logged values
  - **Resume**: Continue suspended computations from where they left off
  - **Rerun**: Re-execute failed computations, replaying successful effects

  ## Architecture

  EffectLogger works by wrapping effect handlers to intercept their invocations.
  Each wrapped handler:

  1. Creates a log entry in `:started` state
  2. Installs a `leave_scope` to mark the entry as `:discarded` if the continuation
     is abandoned (e.g., by a Throw effect)
  3. Wraps the continuation `k` to mark the entry as `:executed` when it completes
  4. Calls the original handler with the wrapped continuation

  ## Flat Log Structure

  Unlike a tree-structured log, entries are stored flat in execution order.
  The `leave_scope` mechanism marks entries as `:discarded` when their
  continuations are abandoned, preserving the information needed for replay.

  ## Example - Basic Logging

      alias Skuld.Comp
      alias Skuld.Effects.{EffectLogger, State}

      {{result, log}, _env} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

  ## Entry States

  - `:started` - Handler invoked, continuation not yet completed (includes suspended)
  - `:executed` - Handler called wrapped_k, continuation completed normally
  - `:discarded` - Handler never called wrapped_k (e.g., Throw effect)

  ## Hot vs Cold Resume

  When a computation suspends (e.g., via Yield), there are two ways to resume:

  ### Hot Resume (In-Memory)

  If you have the live `%Comp.Suspend{}` struct, call the resume function directly:

      alias Skuld.Effects.{EffectLogger, State, Yield}

      # Run until suspension
      {%Comp.Suspend{value: yielded, resume: resume}, env} =
        my_comp
        |> EffectLogger.with_logging()
        |> Yield.with_handler()
        |> State.with_handler(0)
        |> Comp.run()

      # Hot resume - call continuation directly with input
      {result, final_env} = resume.(my_input)

  The resume function captures the live continuation and environment.

  ### Cold Resume (Deserialized)

  If you've serialized the log and later deserialize it, use `with_resume/3,4`:

      alias Skuld.Effects.EffectLogger.Log

      # Serialize log to JSON
      json = Jason.encode!(log)

      # Later... deserialize and cold resume
      cold_log = json |> Jason.decode!() |> Log.from_json()

      {{result, new_log}, _env} =
        my_comp
        |> EffectLogger.with_resume(cold_log, my_input)
        |> Yield.with_handler()
        |> State.with_handler(0)
        |> Comp.run()

  Cold resume re-runs the computation, short-circuits `:executed` entries with
  their logged values, and injects the resume value at the `:started` Yield entry.

  ## Use Cases

  1. **Logging/Tracing**: Capture effect invocations for debugging or audit
  2. **Replay**: Re-run computation, short-circuiting with logged values
  3. **Retry**: Re-run after failure - `:discarded` entries are re-executed
  4. **Resume**: Continue after Yield suspension (hot or cold)

  ## Loop Pruning with mark_loop

  For long-running loop-based computations (like LLM conversation loops), the log
  can grow unboundedly. The `mark_loop/2` operation enables efficient pruning of
  completed loop iterations while preserving checkpoints for recovery.

  ### Basic Usage

      alias Skuld.Effects.{EffectLogger, Yield}

      defcomp conversation_loop(state) do
        # Mark iteration start with checkpoint
        _ <- EffectLogger.mark_loop(ConversationLoop, %{messages: state.messages})

        input <- Yield.yield(:await_input)
        state = handle_input(state, input)

        conversation_loop(state)
      end

      # Run with pruning enabled - no extra handler needed
      {{result, log}, _env} =
        conversation_loop(initial_state)
        |> EffectLogger.with_logging(prune_loops: true)
        |> Yield.with_handler()
        |> Comp.run()

  ### How It Works

  1. Each `EffectLogger.mark_loop(loop_id, checkpoint)` call records a loop iteration boundary
  2. When `prune_loops: true`, completed iterations are removed on finalization
  3. Only the last iteration's effects are retained
  4. Nested loops are handled hierarchically - inner loop pruning doesn't cross outer loop marks

  ### Nested Loops

  For nested loops with different loop-ids, pruning respects the hierarchy:

      defcomp outer_loop(state) do
        _ <- EffectLogger.mark_loop(OuterLoop, %{outer_state: state})
        {result, state} <- inner_loop(state)
        outer_loop(state)
      end

      defcomp inner_loop(state) do
        _ <- EffectLogger.mark_loop(InnerLoop, %{inner_state: state})
        # ... inner loop logic ...
        inner_loop(updated_state)
      end

  The hierarchy `OuterLoop <- InnerLoop` is inferred from nesting order in the log.
  Pruning `InnerLoop` only removes entries between inner loop marks, preserving
  outer loop structure.

  ### Benefits

  - **Bounded log size**: O(current_iteration) instead of O(total_iterations)
  - **Fast cold resume**: Replay only current iteration, not entire history
  - **Preserved semantics**: Full logging within each iteration

  See `EffectLogger.Log` and `EffectLogger.EffectLogEntry` for details.
  """

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Effects.EffectLogger.EffectLogEntry
  alias Skuld.Effects.EffectLogger.Log

  @state_key {__MODULE__, :log}
  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(MarkLoopOp, [:loop_id, :checkpoint], atom_fields: [:loop_id])

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Mark the start of a loop iteration with a loop identifier and optional checkpoint.

  This creates a boundary in the effect log that enables pruning of completed
  loop iterations. Only meaningful when used with `with_logging(prune_loops: true)`.

  ## Parameters

  - `loop_id` - Atom identifying which loop this mark belongs to (module atoms work well)
  - `checkpoint` - (optional) State to restore when resuming from this point

  ## Example

      defcomp conversation_loop(state) do
        # Mark iteration start with checkpoint
        _ <- EffectLogger.mark_loop(ConversationLoop, %{messages: state.messages})

        input <- Yield.yield(:await_input)
        state = handle_input(state, input)

        conversation_loop(state)
      end

      # Run with pruning - only last iteration kept in log
      {{result, log}, _env} =
        conversation_loop(initial_state)
        |> EffectLogger.with_logging(prune_loops: true)
        |> Yield.with_handler()
        |> Comp.run()
  """
  @spec mark_loop(atom(), term()) :: Types.computation()
  def mark_loop(loop_id, checkpoint \\ nil) when is_atom(loop_id) do
    Comp.effect(@sig, %MarkLoopOp{loop_id: loop_id, checkpoint: checkpoint})
  end

  #############################################################################
  ## Handler
  #############################################################################

  @doc """
  Handle EffectLogger operations.

  Currently handles:
  - `MarkLoopOp` - Records loop iteration boundary, returns `:ok`
  """
  @spec handle(term(), Types.env(), Types.k()) :: {Types.result(), Types.env()}
  def handle(%MarkLoopOp{}, env, k) do
    # The mark is recorded by the logging wrapper.
    # This handler just returns :ok to continue the computation.
    k.(:ok, env)
  end

  #############################################################################
  ## Log Access
  #############################################################################

  @doc "Get the current log from the environment"
  @spec get_log(Types.env()) :: Log.t() | nil
  def get_log(env) do
    Env.get_state(env, @state_key)
  end

  @doc "Put a log into the environment"
  @spec put_log(Types.env(), Log.t()) :: Types.env()
  def put_log(env, log) do
    Env.put_state(env, @state_key, log)
  end

  @doc "Update the log in the environment"
  @spec update_log(Types.env(), (Log.t() -> Log.t())) :: Types.env()
  def update_log(env, f) do
    log = get_log(env) || Log.new()
    put_log(env, f.(log))
  end

  #############################################################################
  ## Handler Wrapping
  #############################################################################

  @doc """
  Wrap an effect handler with logging.

  The wrapped handler will log each effect invocation, tracking:
  - When the effect starts (creates entry in `:started` state)
  - When the effect completes (marks entry as `:executed` with value)
  - When the continuation is abandoned (marks entry as `:discarded`)

  ## Parameters

  - `sig` - The effect signature (module) for logging
  - `handler` - The original handler function `(args, env, k) -> {result, env}`

  ## Returns

  A wrapped handler function with the same signature.

  ## Example

      logged_handler = EffectLogger.wrap_handler(State, &State.handle/3)

      comp
      |> Comp.with_handler(State, logged_handler)
      |> EffectLogger.with_logging()
      |> Comp.run()
  """
  @spec wrap_handler(module(), Types.handler()) :: Types.handler()
  def wrap_handler(sig, handler) do
    fn args, env, k ->
      # Generate unique ID for this entry
      entry_id = generate_id()

      # Create entry and push to log
      entry = EffectLogEntry.new(entry_id, sig, args)
      env_with_entry = update_log(env, &Log.push_entry(&1, entry))

      # Save previous leave_scope
      previous_leave_scope = Env.get_leave_scope(env_with_entry)

      # Create leave_scope that marks entry as discarded
      my_leave_scope = fn result, inner_env ->
        # Mark this entry as discarded (set_discarded handles the state transition)
        marked_env = update_log(inner_env, &Log.mark_discarded(&1, entry_id))
        previous_leave_scope.(result, marked_env)
      end

      # Create wrapped continuation that marks entry as executed
      wrapped_k = fn value, inner_env ->
        # Mark entry as executed with the value
        executed_env =
          update_log(inner_env, fn log ->
            update_entry_executed(log, entry_id, value)
          end)

        # Restore previous leave_scope and call original k.
        # Our leave_scope is no longer active - only the current entry's
        # leave_scope can mark it as :discarded (if wrapped_k is never called).
        restored_env = Env.with_leave_scope(executed_env, previous_leave_scope)
        k.(value, restored_env)
      end

      # Install leave_scope and call original handler
      env_with_leave_scope = Env.with_leave_scope(env_with_entry, my_leave_scope)
      Comp.call_handler(handler, args, env_with_leave_scope, wrapped_k)
    end
  end

  # Update an entry in the log to :executed state with a value
  defp update_entry_executed(log, entry_id, value) do
    updated_stack =
      Enum.map(log.effect_stack, fn entry ->
        if entry.id == entry_id do
          EffectLogEntry.set_executed(entry, value)
        else
          entry
        end
      end)

    %{log | effect_stack: updated_stack}
  end

  #############################################################################
  ## Logging Scope
  #############################################################################

  @doc """
  Wrap a computation with effect logging.

  Automatically wraps handlers already installed in the env with logging.
  Initializes the log and extracts it when the computation completes.
  The result is transformed to `{original_result, log}`.

  This should be the INNERMOST wrapper (immediately after the computation
  in the pipe), so it can see handlers installed by outer wrappers.

  ## Variants

  - `with_logging(comp)` - Fresh logging, capture all effects
  - `with_logging(comp, opts)` - Fresh logging with options
  - `with_logging(comp, log)` - Replay from existing log
  - `with_logging(comp, log, opts)` - Replay with options

  ## Options

  - `:effects` - List of effect signatures to log. Default is all handlers in env.
  - `:allow_divergence` - (replay only) If true, allow effects that don't match the log.
  - `:prune_loops` - If true, prune completed loop segments on finalization.
    Requires MarkLoop effect to be used in the computation. See `Skuld.Effects.MarkLoop`.

  ## Example - Fresh Logging

      {{result, log}, _env} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Or specify which effects to log:
      {{result, log}, _env} =
        my_comp
        |> EffectLogger.with_logging(effects: [State])
        |> State.with_handler(0)
        |> Reader.with_handler(:config)
        |> Comp.run()

  ## Example - Replay

      # First run - capture log
      {{result1, log}, _} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Replay - short-circuit with logged values
      {{result2, _}, _} =
        my_comp
        |> EffectLogger.with_logging(log)
        |> State.with_handler(0)
        |> Comp.run()

      assert result1 == result2
  """
  @spec with_logging(Types.computation(), keyword()) :: Types.computation()
  @spec with_logging(Types.computation(), Log.t()) :: Types.computation()
  def with_logging(comp, opts \\ [])

  def with_logging(comp, opts) when is_list(opts) do
    effects_to_log = Keyword.get(opts, :effects, :all)
    prune_loops = Keyword.get(opts, :prune_loops, false)

    Comp.scoped(comp, fn env ->
      # Install EffectLogger's own handler (for mark_loop operations)
      env_with_self = Env.with_handler(env, @sig, &__MODULE__.handle/3)

      # Determine which handlers to wrap (including our own handler)
      sigs_to_wrap =
        case effects_to_log do
          :all -> Map.keys(env_with_self.evidence)
          list when is_list(list) -> [@sig | list] |> Enum.uniq()
        end

      # Wrap each handler with logging and install
      {env_with_wrapped, original_handlers} =
        Enum.reduce(sigs_to_wrap, {env_with_self, %{}}, fn sig, {acc_env, originals} ->
          case Env.get_handler(acc_env, sig) do
            nil ->
              {acc_env, originals}

            handler ->
              wrapped = wrap_handler(sig, handler)
              new_env = Env.with_handler(acc_env, sig, wrapped)
              {new_env, Map.put(originals, sig, handler)}
          end
        end)

      # Initialize empty log
      env_with_log = put_log(env_with_wrapped, Log.new())

      finally_k = fn value, final_env ->
        # Extract and finalize the log
        log = get_log(final_env) || Log.new()
        finalized_log = Log.finalize(log)

        # Optionally prune completed loop segments
        output_log =
          if prune_loops do
            Log.prune_completed_loops(finalized_log)
          else
            finalized_log
          end

        # Clean up log from env state
        cleaned_env = %{final_env | state: Map.delete(final_env.state, @state_key)}

        # Restore original handlers
        restored_env =
          Enum.reduce(original_handlers, cleaned_env, fn {sig, original}, acc_env ->
            Env.with_handler(acc_env, sig, original)
          end)

        # Return result paired with log
        {{value, output_log}, restored_env}
      end

      {env_with_log, finally_k}
    end)
  end

  def with_logging(comp, %Log{} = log), do: with_logging(comp, log, [])

  @spec with_logging(Types.computation(), Log.t(), keyword()) :: Types.computation()
  def with_logging(comp, %Log{} = log, opts) when is_list(opts) do
    effects_to_log = Keyword.get(opts, :effects, :all)
    allow_divergence = Keyword.get(opts, :allow_divergence, false)
    prune_loops = Keyword.get(opts, :prune_loops, false)

    Comp.scoped(comp, fn env ->
      # Install EffectLogger's own handler (for mark_loop operations)
      env_with_self = Env.with_handler(env, @sig, &__MODULE__.handle/3)

      # Determine which handlers to wrap (including our own handler)
      sigs_to_wrap =
        case effects_to_log do
          :all -> Map.keys(env_with_self.evidence)
          list when is_list(list) -> [@sig | list] |> Enum.uniq()
        end

      # Wrap each handler with replay logging and install
      {env_with_wrapped, original_handlers} =
        Enum.reduce(sigs_to_wrap, {env_with_self, %{}}, fn sig, {acc_env, originals} ->
          case Env.get_handler(acc_env, sig) do
            nil ->
              {acc_env, originals}

            handler ->
              wrapped = wrap_replay_handler(sig, handler)
              new_env = Env.with_handler(acc_env, sig, wrapped)
              {new_env, Map.put(originals, sig, handler)}
          end
        end)

      # Initialize with existing log (prepared for replay)
      replay_log =
        if allow_divergence do
          Log.allow_divergence(log)
        else
          log
        end

      env_with_log = put_log(env_with_wrapped, replay_log)

      finally_k = fn value, final_env ->
        # Extract and finalize the log
        final_log = get_log(final_env) || Log.new()
        finalized_log = Log.finalize(final_log)

        # Optionally prune completed loop segments
        output_log =
          if prune_loops do
            Log.prune_completed_loops(finalized_log)
          else
            finalized_log
          end

        # Clean up log from env state
        cleaned_env = %{final_env | state: Map.delete(final_env.state, @state_key)}

        # Restore original handlers
        restored_env =
          Enum.reduce(original_handlers, cleaned_env, fn {sig, original}, acc_env ->
            Env.with_handler(acc_env, sig, original)
          end)

        # Return result paired with log
        {{value, output_log}, restored_env}
      end

      {env_with_log, finally_k}
    end)
  end

  #############################################################################
  ## Replay Handler
  #############################################################################

  @doc """
  Wrap a handler for replay mode.

  During replay, if the next entry in the log queue matches this effect
  and can be short-circuited, returns the logged value directly.
  Otherwise, executes the handler normally.

  ## Parameters

  - `sig` - The effect signature (module)
  - `handler` - The original handler function

  ## Example

      replay_handler = EffectLogger.wrap_replay_handler(State, &State.handle/3)

      {{result, _log}, _env} =
        my_comp
        |> Comp.with_handler(State, replay_handler)
        |> EffectLogger.with_logging(previous_log)
        |> Comp.run()
  """
  @spec wrap_replay_handler(module(), Types.handler()) :: Types.handler()
  def wrap_replay_handler(sig, handler) do
    fn args, env, k ->
      log = get_log(env) || Log.new()

      case Log.peek_queue(log) do
        %EffectLogEntry{} = entry ->
          cond do
            EffectLogEntry.matches?(entry, sig, args) and
                EffectLogEntry.can_short_circuit?(entry) ->
              # Short-circuit: pop entry from queue and return logged value
              {_entry, updated_log} = Log.pop_queue(log)
              env_with_updated_log = put_log(env, updated_log)
              k.(entry.value, env_with_updated_log)

            EffectLogEntry.matches?(entry, sig, args) ->
              # Matches but can't short-circuit (e.g., :discarded) - pop and re-execute
              {_entry, updated_log} = Log.pop_queue(log)
              env_with_updated_log = put_log(env, updated_log)
              wrap_handler(sig, handler).(args, env_with_updated_log, k)

            true ->
              # Doesn't match - divergence, execute normally without popping
              wrap_handler(sig, handler).(args, env, k)
          end

        nil ->
          # No entries in queue - execute normally with logging
          wrap_handler(sig, handler).(args, env, k)
      end
    end
  end

  #############################################################################
  ## Cold Resume
  #############################################################################

  @resume_value_key {__MODULE__, :resume_value}

  # Resume value helpers - use wrapper tuple to distinguish nil from unset
  defp get_resume_value(env) do
    case Env.get_state(env, @resume_value_key) do
      {:resume_value, value} -> {:ok, value}
      nil -> :not_set
    end
  end

  defp put_resume_value(env, value) do
    Env.put_state(env, @resume_value_key, {:resume_value, value})
  end

  defp clear_resume_value(env) do
    %{env | state: Map.delete(env.state, @resume_value_key)}
  end

  @doc """
  Resume a suspended computation from a cold (deserialized) log.

  Re-runs the computation from scratch, short-circuiting completed effects with
  their logged values. When reaching the suspension point (the `:started` Yield
  entry), injects `resume_value` instead of actually suspending, then continues
  with fresh execution.

  ## Parameters

  - `comp` - The computation to run
  - `log` - The log ending with a `:started` Yield entry (from suspension)
  - `resume_value` - The value to inject at the suspension point
  - `opts` - Options (same as `with_logging/3`)

  ## Example

      alias Skuld.Effects.EffectLogger.Log

      # Original run - suspended
      {{%Comp.Suspend{value: yielded}, log}, _} =
        my_comp
        |> EffectLogger.with_logging()
        |> Yield.with_handler()
        |> State.with_handler(0)
        |> Comp.run()

      # Serialize and later deserialize
      json = Log.to_json(log)
      {:ok, cold_log} = Log.from_json(json)

      # Cold resume with injected value
      {{result, new_log}, _} =
        my_comp
        |> EffectLogger.with_resume(cold_log, :my_input)
        |> Yield.with_handler()
        |> State.with_handler(0)
        |> Comp.run()
  """
  @spec with_resume(Types.computation(), Log.t(), term()) :: Types.computation()
  def with_resume(comp, log, resume_value), do: with_resume(comp, log, resume_value, [])

  @spec with_resume(Types.computation(), Log.t(), term(), keyword()) :: Types.computation()
  def with_resume(comp, %Log{} = log, resume_value, opts) when is_list(opts) do
    effects_to_log = Keyword.get(opts, :effects, :all)
    allow_divergence = Keyword.get(opts, :allow_divergence, false)
    prune_loops = Keyword.get(opts, :prune_loops, false)

    Comp.scoped(comp, fn env ->
      # Install EffectLogger's own handler (for mark_loop operations)
      env_with_self = Env.with_handler(env, @sig, &__MODULE__.handle/3)

      # Determine which handlers to wrap (including our own handler)
      sigs_to_wrap =
        case effects_to_log do
          :all -> Map.keys(env_with_self.evidence)
          list when is_list(list) -> [@sig | list] |> Enum.uniq()
        end

      # Wrap each handler with resume logging and install
      {env_with_wrapped, original_handlers} =
        Enum.reduce(sigs_to_wrap, {env_with_self, %{}}, fn sig, {acc_env, originals} ->
          case Env.get_handler(acc_env, sig) do
            nil ->
              {acc_env, originals}

            handler ->
              wrapped = wrap_resume_handler(sig, handler)
              new_env = Env.with_handler(acc_env, sig, wrapped)
              {new_env, Map.put(originals, sig, handler)}
          end
        end)

      # Initialize with existing log (prepared for replay) and resume value
      replay_log =
        if allow_divergence do
          Log.allow_divergence(log)
        else
          log
        end

      env_with_log = put_log(env_with_wrapped, replay_log)
      env_with_resume = put_resume_value(env_with_log, resume_value)

      finally_k = fn value, final_env ->
        # Extract and finalize the log
        final_log = get_log(final_env) || Log.new()
        finalized_log = Log.finalize(final_log)

        # Optionally prune completed loop segments
        output_log =
          if prune_loops do
            Log.prune_completed_loops(finalized_log)
          else
            finalized_log
          end

        # Clean up log and resume value from env state
        cleaned_env =
          final_env
          |> then(fn e -> %{e | state: Map.delete(e.state, @state_key)} end)
          |> clear_resume_value()

        # Restore original handlers
        restored_env =
          Enum.reduce(original_handlers, cleaned_env, fn {sig, original}, acc_env ->
            Env.with_handler(acc_env, sig, original)
          end)

        # Return result paired with log
        {{value, output_log}, restored_env}
      end

      {env_with_resume, finally_k}
    end)
  end

  @doc """
  Wrap a handler for resume mode.

  Like `wrap_replay_handler/2`, but when encountering a `:started` Yield entry
  (the suspension point), injects the stored resume value instead of suspending.

  The resume value is stored in env by `with_resume/4` and cleared after use.

  ## Parameters

  - `sig` - The effect signature (module)
  - `handler` - The original handler function

  ## Returns

  A wrapped handler function.
  """
  @spec wrap_resume_handler(module(), Types.handler()) :: Types.handler()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def wrap_resume_handler(sig, handler) do
    fn args, env, k ->
      log = get_log(env) || Log.new()

      case Log.peek_queue(log) do
        %EffectLogEntry{} = entry ->
          cond do
            # Can short-circuit: pop and return logged value
            EffectLogEntry.matches?(entry, sig, args) and
                EffectLogEntry.can_short_circuit?(entry) ->
              {_entry, updated_log} = Log.pop_queue(log)
              env_with_updated_log = put_log(env, updated_log)
              k.(entry.value, env_with_updated_log)

            # Yield suspension point with resume value: inject it
            EffectLogEntry.matches?(entry, sig, args) and
              sig == Skuld.Effects.Yield and
              entry.state == :started and
                get_resume_value(env) != :not_set ->
              {:ok, resume_value} = get_resume_value(env)
              {_entry, updated_log} = Log.pop_queue(log)
              env_with_updated_log = put_log(env, updated_log)
              # Clear resume value so subsequent Yields execute normally
              env_cleared = clear_resume_value(env_with_updated_log)
              # Log this as a new executed entry (the resumed Yield)
              entry_id = generate_id()

              resumed_entry =
                EffectLogEntry.new(entry_id, sig, args)
                |> EffectLogEntry.set_executed(resume_value)

              env_with_entry = update_log(env_cleared, &Log.push_entry(&1, resumed_entry))
              k.(resume_value, env_with_entry)

            # Matches but can't short-circuit - pop and re-execute
            EffectLogEntry.matches?(entry, sig, args) ->
              {_entry, updated_log} = Log.pop_queue(log)
              env_with_updated_log = put_log(env, updated_log)
              wrap_handler(sig, handler).(args, env_with_updated_log, k)

            # Doesn't match - divergence, execute normally without popping
            true ->
              wrap_handler(sig, handler).(args, env, k)
          end

        nil ->
          # No entries in queue - execute normally with logging
          wrap_handler(sig, handler).(args, env, k)
      end
    end
  end

  #############################################################################
  ## Private
  #############################################################################

  defp generate_id do
    Uniq.UUID.uuid4()
  end
end
