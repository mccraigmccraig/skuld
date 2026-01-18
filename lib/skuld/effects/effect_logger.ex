defmodule Skuld.Effects.EffectLogger do
  @behaviour Skuld.Comp.IHandler

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
  can grow unboundedly. The `mark_loop/1` operation enables efficient pruning of
  completed loop iterations while preserving state checkpoints for cold resume.

  ### Basic Usage

      alias Skuld.Effects.{EffectLogger, Yield}

      defcomp conversation_loop(state) do
        # Mark iteration start - env.state is captured automatically
        _ <- EffectLogger.mark_loop(ConversationLoop)

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

  1. A root mark (`:__root__`) is auto-inserted on the first intercepted effect,
     capturing the initial `env.state`
  2. Each `EffectLogger.mark_loop(loop_id)` captures current `env.state`
  3. When `prune_loops: true`, completed iterations are removed on finalization
  4. Only the last iteration's effects are retained, plus checkpoints
  5. Cold resume restores `env.state` from the most recent checkpoint

  ### Nested Loops

  For nested loops with different loop-ids, pruning respects the hierarchy:

      defcomp outer_loop(state) do
        _ <- EffectLogger.mark_loop(OuterLoop)
        {result, state} <- inner_loop(state)
        outer_loop(state)
      end

      defcomp inner_loop(state) do
        _ <- EffectLogger.mark_loop(InnerLoop)
        # ... inner loop logic ...
        inner_loop(updated_state)
      end

  The hierarchy `:__root__ <- OuterLoop <- InnerLoop` is inferred from nesting
  order. Pruning `InnerLoop` only removes entries between inner loop marks,
  preserving outer loop structure. The root mark is never pruned.

  ### Benefits

  - **Bounded log size**: O(current_iteration) instead of O(total_iterations)
  - **Fast cold resume**: Replay only current iteration, not entire history
  - **State restoration**: `env.state` is restored from checkpoint on cold resume
  - **Preserved semantics**: Full logging within each iteration

  See `EffectLogger.Log` and `EffectLogger.EffectLogEntry` for details.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Suspend
  alias Skuld.Comp.Types
  alias Skuld.Effects.EffectLogger.EffectLogEntry
  alias Skuld.Effects.EffectLogger.EnvStateSnapshot
  alias Skuld.Effects.EffectLogger.Log

  @state_key {__MODULE__, :log}
  @state_keys_key {__MODULE__, :state_keys}
  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  defmodule MarkLoop do
    @moduledoc """
    Operation struct for loop iteration marks.

    Contains the loop_id and a snapshot of env.state for cold resume.
    """

    alias Skuld.Effects.EffectLogger.EnvStateSnapshot

    defstruct [:loop_id, :env_state]

    @type t :: %__MODULE__{
            loop_id: atom(),
            env_state: EnvStateSnapshot.t() | nil
          }

    @doc """
    Reconstruct from decoded JSON map.
    """
    @spec from_json(map()) :: t()
    def from_json(map) do
      loop_id =
        case map["loop_id"] || map[:loop_id] do
          s when is_binary(s) -> String.to_existing_atom(s)
          a when is_atom(a) -> a
          nil -> nil
        end

      env_state =
        case map["env_state"] || map[:env_state] do
          nil -> nil
          %EnvStateSnapshot{} = s -> s
          m when is_map(m) -> EnvStateSnapshot.from_json(m)
        end

      %__MODULE__{loop_id: loop_id, env_state: env_state}
    end
  end

  defimpl Jason.Encoder, for: Skuld.Effects.EffectLogger.MarkLoop do
    def encode(value, opts) do
      value
      |> Skuld.Comp.SerializableStruct.encode()
      |> Jason.Encode.map(opts)
    end
  end

  @root_loop_id :__root__

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Mark the start of a loop iteration with a loop identifier.

  This creates a boundary in the effect log that enables pruning of completed
  loop iterations. The current `env.state` is automatically captured for
  cold resume. Only meaningful when used with `with_logging(prune_loops: true)`.

  ## Parameters

  - `loop_id` - Atom identifying which loop this mark belongs to (module atoms work well)

  ## Example

      defcomp conversation_loop(state) do
        # Mark iteration start - env.state captured automatically
        _ <- EffectLogger.mark_loop(ConversationLoop)

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
  @spec mark_loop(atom()) :: Types.computation()
  def mark_loop(loop_id) when is_atom(loop_id) do
    # env_state will be captured by wrap_handler when this effect is logged
    Comp.effect(@sig, %MarkLoop{loop_id: loop_id, env_state: nil})
  end

  @doc """
  Returns the root loop ID used for the implicit root mark.
  """
  @spec root_loop_id() :: atom()
  def root_loop_id, do: @root_loop_id

  #############################################################################
  ## Handler
  #############################################################################

  @doc """
  Handle EffectLogger operations.

  Currently handles:
  - `MarkLoop` - Records loop iteration boundary, returns `:ok`
  """
  @spec handle(term(), Types.env(), Types.k()) :: {Types.result(), Types.env()}
  @impl Skuld.Comp.IHandler
  def handle(%MarkLoop{}, env, k) do
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

  # Get the state_keys filter from env (internal)
  defp get_state_keys(env) do
    Env.get_state(env, @state_keys_key) || :all
  end

  # Put state_keys filter into env (internal)
  defp put_state_keys(env, state_keys) do
    Env.put_state(env, @state_keys_key, state_keys)
  end

  # Capture env.state snapshot with configured state_keys filter
  defp capture_state_snapshot(env) do
    state_keys = get_state_keys(env)
    EnvStateSnapshot.capture(env.state, state_keys: state_keys)
  end

  # Decorate a Suspend with the current log in Suspend.data
  defp decorate_suspend_with_log(%Suspend{} = suspend, env) do
    log = get_log(env)
    finalized_log = if log, do: Log.finalize(log), else: nil

    data = suspend.data || %{}
    decorated = %{suspend | data: Map.put(data, __MODULE__, finalized_log)}
    {decorated, env}
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
      # Ensure root mark exists (lazy insertion on first intercepted effect)
      env_with_root = ensure_root_mark(env)

      # Generate unique ID for this entry
      entry_id = generate_id()

      # For MarkLoop, capture current env.state as a serializable snapshot
      entry_data =
        if sig == __MODULE__ and match?(%MarkLoop{}, args) do
          %{args | env_state: capture_state_snapshot(env_with_root)}
        else
          args
        end

      # Create entry and push to log
      entry = EffectLogEntry.new(entry_id, sig, entry_data)
      env_with_entry = update_log(env_with_root, &Log.push_entry(&1, entry))

      # Save previous leave_scope
      previous_leave_scope = Env.get_leave_scope(env_with_entry)

      # Create leave_scope that marks entry as discarded
      my_leave_scope = fn result, inner_env ->
        # Mark this entry as discarded (set_discarded handles the state transition)
        marked_env = update_log(inner_env, &Log.mark_discarded(&1, entry_id))
        previous_leave_scope.(result, marked_env)
      end

      # Track whether this is a mark_loop effect for eager pruning
      is_mark_loop = sig == __MODULE__ and match?(%MarkLoop{}, args)

      # Create wrapped continuation that marks entry as executed
      wrapped_k = fn value, inner_env ->
        # Mark entry as executed with the value
        executed_env =
          update_log(inner_env, fn log ->
            update_entry_executed(log, entry_id, value)
          end)

        # Eagerly prune after mark_loop if prune_on_mark? is enabled
        pruned_env =
          if is_mark_loop do
            update_log(executed_env, fn log ->
              if log.prune_on_mark? do
                # Prune in place - keeps entries on stack for correct ordering
                Log.prune_in_place(log)
              else
                log
              end
            end)
          else
            executed_env
          end

        # Restore previous leave_scope and call original k.
        # Our leave_scope is no longer active - only the current entry's
        # leave_scope can mark it as :discarded (if wrapped_k is never called).
        restored_env = Env.with_leave_scope(pruned_env, previous_leave_scope)
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
  - `:prune_loops` - If true (default), prune completed loop segments eagerly after each
    `mark_loop/1` call. This keeps memory bounded during long-running computations.
    Set to `false` to preserve all entries (e.g., for debugging).
  - `:state_keys` - List of env.state keys to include in `EnvStateSnapshot` captures.
    Default `:all` includes everything. Use this to filter out constant Reader state:

        state_keys: [{Skuld.Effects.State, MyApp.Counter}]

    This only captures the specified State keys, excluding Reader/other constant state.
  - `:decorate_suspend` - If true (default), attach the current finalized log to
    `Suspend.data[EffectLogger]` when yielding. This allows AsyncRunner callers to
    access the log without needing the full env. Set to `false` to disable.

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
    prune_loops = Keyword.get(opts, :prune_loops, true)
    state_keys = Keyword.get(opts, :state_keys, :all)
    decorate_suspend = Keyword.get(opts, :decorate_suspend, true)

    Comp.scoped(comp, fn env ->
      env_with_config = setup_logging_env(env, state_keys)
      sigs_to_wrap = sigs_to_wrap(effects_to_log, env_with_config)

      {env_with_wrapped, original_handlers} =
        install_wrapped_handlers(env_with_config, sigs_to_wrap, &wrap_handler/2)

      initial_log = init_log_with_prune(Log.new(), prune_loops)
      env_with_log = put_log(env_with_wrapped, initial_log)

      {env_final, previous_transform} =
        maybe_setup_suspend_decoration(env_with_log, decorate_suspend)

      finally_k = build_finally_k(prune_loops, original_handlers, previous_transform)

      {env_final, finally_k}
    end)
  end

  def with_logging(comp, %Log{} = log), do: with_logging(comp, log, [])

  @spec with_logging(Types.computation(), Log.t(), keyword()) :: Types.computation()
  def with_logging(comp, %Log{} = log, opts) when is_list(opts) do
    effects_to_log = Keyword.get(opts, :effects, :all)
    allow_divergence = Keyword.get(opts, :allow_divergence, false)
    prune_loops = Keyword.get(opts, :prune_loops, true)
    state_keys = Keyword.get(opts, :state_keys, :all)
    decorate_suspend = Keyword.get(opts, :decorate_suspend, true)

    Comp.scoped(comp, fn env ->
      env_with_config = setup_logging_env(env, state_keys)
      sigs_to_wrap = sigs_to_wrap(effects_to_log, env_with_config)

      {env_with_wrapped, original_handlers} =
        install_wrapped_handlers(env_with_config, sigs_to_wrap, &wrap_replay_handler/2)

      replay_log = init_replay_log(log, prune_loops, allow_divergence)
      env_with_log = put_log(env_with_wrapped, replay_log)

      {env_final, previous_transform} =
        maybe_setup_suspend_decoration(env_with_log, decorate_suspend)

      finally_k = build_finally_k(prune_loops, original_handlers, previous_transform)

      {env_final, finally_k}
    end)
  end

  @doc """
  Install EffectLogger via catch clause syntax.

  Config is opts, a Log for replay, or `{log, opts}`:

      catch
        EffectLogger -> nil                    # fresh logging
        EffectLogger -> [effects: [State]]     # log specific effects
        EffectLogger -> log                    # replay from log
        EffectLogger -> {log, allow_divergence: true}  # replay with opts
  """
  @impl Skuld.Comp.IHandler
  def __handle__(comp, nil), do: with_logging(comp)
  def __handle__(comp, opts) when is_list(opts), do: with_logging(comp, opts)
  def __handle__(comp, %Log{} = log), do: with_logging(comp, log)
  def __handle__(comp, {%Log{} = log, opts}) when is_list(opts), do: with_logging(comp, log, opts)

  # Private helpers to reduce cyclomatic complexity

  defp setup_logging_env(env, state_keys) do
    env
    |> Env.with_handler(@sig, &__MODULE__.handle/3)
    |> put_state_keys(state_keys)
  end

  defp sigs_to_wrap(:all, env), do: Map.keys(env.evidence)
  defp sigs_to_wrap(list, _env) when is_list(list), do: [@sig | list] |> Enum.uniq()

  defp install_wrapped_handlers(env, sigs, wrapper_fn) do
    Enum.reduce(sigs, {env, %{}}, fn sig, {acc_env, originals} ->
      case Env.get_handler(acc_env, sig) do
        nil ->
          {acc_env, originals}

        handler ->
          wrapped = wrapper_fn.(sig, handler)
          new_env = Env.with_handler(acc_env, sig, wrapped)
          {new_env, Map.put(originals, sig, handler)}
      end
    end)
  end

  defp init_log_with_prune(log, true), do: Log.enable_prune_on_mark(log)
  defp init_log_with_prune(log, false), do: log

  defp init_replay_log(log, prune_loops, allow_divergence) do
    log
    |> init_log_with_prune(prune_loops)
    |> maybe_allow_divergence(allow_divergence)
  end

  defp maybe_allow_divergence(log, true), do: Log.allow_divergence(log)
  defp maybe_allow_divergence(log, false), do: log

  defp maybe_setup_suspend_decoration(env, false), do: {env, nil}

  defp maybe_setup_suspend_decoration(env, true) do
    old_transform = Env.get_transform_suspend(env)

    new_transform = fn suspend, e ->
      {suspend1, e1} = old_transform.(suspend, e)
      decorate_suspend_with_log(suspend1, e1)
    end

    {Env.with_transform_suspend(env, new_transform), old_transform}
  end

  defp build_finally_k(prune_loops, original_handlers, previous_transform) do
    fn value, final_env ->
      log = get_log(final_env) || Log.new()
      finalized_log = Log.finalize(log)
      output_log = maybe_prune_log(finalized_log, prune_loops)

      cleaned_env = cleanup_logger_state(final_env)
      restored_env = restore_original_handlers(cleaned_env, original_handlers)
      restored_env = maybe_restore_transform(restored_env, previous_transform)

      {{value, output_log}, restored_env}
    end
  end

  defp maybe_prune_log(log, true), do: Log.prune_completed_loops(log)
  defp maybe_prune_log(log, false), do: log

  defp cleanup_logger_state(env) do
    %{env | state: env.state |> Map.delete(@state_key) |> Map.delete(@state_keys_key)}
  end

  defp restore_original_handlers(env, original_handlers) do
    Enum.reduce(original_handlers, env, fn {sig, original}, acc_env ->
      Env.with_handler(acc_env, sig, original)
    end)
  end

  defp maybe_restore_transform(env, nil), do: env
  defp maybe_restore_transform(env, transform), do: Env.with_transform_suspend(env, transform)

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
      # Skip any loop marks at front of queue, validating state consistency
      env_after_marks = skip_loop_marks(env)
      log = get_log(env_after_marks) || Log.new()

      case Log.peek_queue(log) do
        %EffectLogEntry{} = entry ->
          cond do
            EffectLogEntry.matches?(entry, sig, args) and
                EffectLogEntry.can_short_circuit?(entry) ->
              # Short-circuit: pop entry from queue and return logged value
              {_entry, updated_log} = Log.pop_queue(log)
              env_with_updated_log = put_log(env_after_marks, updated_log)
              k.(entry.value, env_with_updated_log)

            EffectLogEntry.matches?(entry, sig, args) ->
              # Matches but can't short-circuit (e.g., :discarded) - pop and re-execute
              {_entry, updated_log} = Log.pop_queue(log)
              env_with_updated_log = put_log(env_after_marks, updated_log)
              wrap_handler(sig, handler).(args, env_with_updated_log, k)

            true ->
              # Doesn't match - divergence, execute normally without popping
              wrap_handler(sig, handler).(args, env_after_marks, k)
          end

        nil ->
          # No entries in queue - execute normally with logging
          wrap_handler(sig, handler).(args, env_after_marks, k)
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
    prune_loops = Keyword.get(opts, :prune_loops, true)
    state_keys = Keyword.get(opts, :state_keys, :all)

    Comp.scoped(comp, fn env ->
      # Install EffectLogger's own handler (for mark_loop operations)
      env_with_self = Env.with_handler(env, @sig, &__MODULE__.handle/3)

      # Store state_keys filter for use in snapshots
      env_with_config = put_state_keys(env_with_self, state_keys)

      # Determine which handlers to wrap (including our own handler)
      sigs_to_wrap =
        case effects_to_log do
          :all -> Map.keys(env_with_config.evidence)
          list when is_list(list) -> [@sig | list] |> Enum.uniq()
        end

      # Wrap each handler with resume logging and install
      {env_with_wrapped, original_handlers} =
        Enum.reduce(sigs_to_wrap, {env_with_config, %{}}, fn sig, {acc_env, originals} ->
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
      # Enable prune_on_mark if prune_loops is true (or preserve from log)
      replay_log =
        log
        |> then(fn l -> if prune_loops, do: Log.enable_prune_on_mark(l), else: l end)
        |> then(fn l -> if allow_divergence, do: Log.allow_divergence(l), else: l end)

      env_with_log = put_log(env_with_wrapped, replay_log)

      # Restore env.state from the most recent checkpoint in the log
      env_with_restored_state = restore_checkpoint_state(env_with_log)

      env_with_resume = put_resume_value(env_with_restored_state, resume_value)

      finally_k = fn value, final_env ->
        # Extract and finalize the log
        final_log = get_log(final_env) || Log.new()
        finalized_log = Log.finalize(final_log)

        # Final prune (may be redundant if eager pruning is enabled, but ensures consistency)
        output_log =
          if prune_loops do
            Log.prune_completed_loops(finalized_log)
          else
            finalized_log
          end

        # Clean up log, state_keys filter, and resume value from env state
        cleaned_env =
          final_env
          |> then(fn e ->
            %{e | state: e.state |> Map.delete(@state_key) |> Map.delete(@state_keys_key)}
          end)
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

  # Predicate: entry matches and can be short-circuited (return cached value)
  defp can_short_circuit_entry?(entry, sig, args) do
    EffectLogEntry.matches?(entry, sig, args) and EffectLogEntry.can_short_circuit?(entry)
  end

  # Predicate: entry is a Yield suspension point that should be resumed
  defp yield_suspension_to_resume?(entry, sig, args, env) do
    EffectLogEntry.matches?(entry, sig, args) and
      sig == Skuld.Effects.Yield and
      entry.state == :started and
      has_resume_value?(env)
  end

  # Predicate: entry matches but needs re-execution (can't short-circuit)
  defp matches_but_needs_reexecution?(entry, sig, args) do
    EffectLogEntry.matches?(entry, sig, args)
  end

  defp has_resume_value?(env), do: get_resume_value(env) != :not_set

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
  def wrap_resume_handler(sig, handler) do
    fn args, env, k ->
      # Skip any loop marks at front of queue, validating state consistency
      env_after_marks = skip_loop_marks(env)
      log = get_log(env_after_marks) || Log.new()

      case Log.peek_queue(log) do
        %EffectLogEntry{} = entry ->
          cond do
            can_short_circuit_entry?(entry, sig, args) ->
              short_circuit_entry(entry, log, env_after_marks, k)

            yield_suspension_to_resume?(entry, sig, args, env_after_marks) ->
              resume_yield_suspension(entry, sig, args, log, env_after_marks, k)

            matches_but_needs_reexecution?(entry, sig, args) ->
              reexecute_entry(sig, handler, args, log, env_after_marks, k)

            true ->
              # Doesn't match - divergence, execute normally without popping
              wrap_handler(sig, handler).(args, env_after_marks, k)
          end

        nil ->
          # No entries in queue - execute normally with logging
          wrap_handler(sig, handler).(args, env_after_marks, k)
      end
    end
  end

  # Short-circuit: pop entry and return its cached value
  defp short_circuit_entry(entry, log, env, k) do
    {_entry, updated_log} = Log.pop_queue(log)
    env_with_updated_log = put_log(env, updated_log)
    k.(entry.value, env_with_updated_log)
  end

  # Resume a Yield suspension: inject the resume value and log the resumed entry
  defp resume_yield_suspension(_entry, sig, args, log, env, k) do
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
  end

  # Re-execute: pop entry and call the wrapped handler
  defp reexecute_entry(sig, handler, args, log, env, k) do
    {_entry, updated_log} = Log.pop_queue(log)
    env_with_updated_log = put_log(env, updated_log)
    wrap_handler(sig, handler).(args, env_with_updated_log, k)
  end

  #############################################################################
  ## Private
  #############################################################################

  defp generate_id do
    Uniq.UUID.uuid4()
  end

  # Ensure the root mark exists in the log (lazy insertion on first effect)
  # Always inserts root mark to capture initial env.state for cold resume
  defp ensure_root_mark(env) do
    log = get_log(env) || Log.new()

    if Log.has_root_mark?(log) do
      env
    else
      root_entry =
        EffectLogEntry.new(
          generate_id(),
          __MODULE__,
          %MarkLoop{loop_id: @root_loop_id, env_state: capture_state_snapshot(env)}
        )
        |> EffectLogEntry.set_executed(:ok)

      update_log(env, &Log.push_entry(&1, root_entry))
    end
  end

  # Restore env.state from the most recent checkpoint in the log (for cold resume)
  defp restore_checkpoint_state(env) do
    log = get_log(env)

    case Log.find_latest_checkpoint(log) do
      nil ->
        env

      %EffectLogEntry{data: %{env_state: %EnvStateSnapshot{} = snapshot}} ->
        restored_state = EnvStateSnapshot.restore(snapshot)
        %{env | state: Map.merge(env.state, restored_state)}

      _ ->
        env
    end
  end

  # Skip any MarkLoop entries at the front of the queue during replay.
  # These are checkpoints for state restoration, not user effects.
  # If divergence is not allowed, validates that current state matches checkpoint.
  defp skip_loop_marks(env) do
    log = get_log(env) || Log.new()

    case Log.peek_queue(log) do
      %EffectLogEntry{sig: sig, data: %MarkLoop{env_state: checkpoint_state}} = entry
      when sig == __MODULE__ ->
        # Pop the mark entry
        {_entry, updated_log} = Log.pop_queue(log)

        # Validate state consistency if not allowing divergence
        if not updated_log.allow_divergence? and checkpoint_state != nil do
          validate_state_consistency(env, checkpoint_state, entry)
        end

        # Update env and recurse to skip any additional marks
        env_with_updated_log = put_log(env, updated_log)
        skip_loop_marks(env_with_updated_log)

      _ ->
        # Not a mark entry, return env unchanged
        env
    end
  end

  # Validate that current env.state is consistent with the checkpoint snapshot.
  # For now, just compare the user state (excluding EffectLogger internal state).
  defp validate_state_consistency(env, %EnvStateSnapshot{} = checkpoint_state, entry) do
    current_snapshot = capture_state_snapshot(env)

    if current_snapshot.entries != checkpoint_state.entries do
      raise """
      State divergence detected during replay.

      Loop mark: #{inspect(entry.data.loop_id)}

      Expected state (from log):
      #{inspect(checkpoint_state.entries, pretty: true)}

      Actual state:
      #{inspect(current_snapshot.entries, pretty: true)}

      Use `allow_divergence: true` option if state changes are expected.
      """
    end
  end

  defp validate_state_consistency(_env, _checkpoint_state, _entry), do: :ok
end
