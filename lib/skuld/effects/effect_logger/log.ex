defmodule Skuld.Effects.EffectLogger.Log do
  @moduledoc """
  A flat log of effect invocations.

  The log captures effects in execution order (when they started), enabling:

  - **Replay**: Short-circuit completed entries with their logged values
  - **Resume**: Continue suspended computations from where they left off
  - **Rerun**: Re-execute failed computations, replaying successful entries

  ## Flat Structure

  Unlike a tree-structured log, this log stores entries in a flat list ordered
  by when each effect started. The hierarchical structure of the computation
  is NOT captured. Instead, we use `leave_scope` handlers to mark entries as
  `:discarded` when their continuations are abandoned (e.g., by a Throw effect).

  ## Stack/Queue Model

  - `effect_stack` - Entries being built during execution (newest first)
  - `effect_queue` - Entries to replay (oldest first) during resume/rerun
  - `allow_divergence?` - Whether to accept effects that don't match the log

  ## Example: Throw with Catch

  Consider a computation where EffectC throws and is caught:

      EffectA fires → completes normally
        ↳ [catch scope]
          ↳ EffectB fires → handler completes
            ↳ EffectC fires (Throw) → discards continuation
            ↳ leave_scope marks C as :discarded
          ↳ leave_scope marks B as :discarded
        ↳ catch intercepts
          ↳ EffectD fires → completes normally
      ↳ EffectA completes

  Resulting flat log:

      [
        {A, :executed, value_A},
        {B, :discarded, value_B},   # has value - handler called wrapped_k
        {C, :discarded, nil},       # no value - handler discarded k
        {D, :executed, value_D}
      ]

  ## Lifecycle

  ### First Run
  1. Effects create entries pushed to `effect_stack`
  2. `leave_scope` handlers mark entries as `:discarded` when continuations are abandoned
  3. On finalize, stack is moved to queue for future replay

  ### Replay/Resume
  1. `effect_queue` contains entries from previous run
  2. Effects check if they match queue head
  3. If match and can short-circuit, return logged value
  4. If match but cannot short-circuit, re-execute handler
  5. If no match and divergence allowed, continue with fresh execution

  ## Divergence

  By default, effects must match the log exactly (strict mode).
  For rerun scenarios with patched code, enable divergence to allow
  the computation to take a different path.
  """

  alias Skuld.Effects.EffectLogger.EffectLogEntry

  defstruct effect_stack: [],
            effect_queue: [],
            allow_divergence?: false

  @type t :: %__MODULE__{
          effect_stack: [EffectLogEntry.t()],
          effect_queue: [EffectLogEntry.t()],
          allow_divergence?: boolean()
        }

  @doc """
  Create a new empty log or a log with entries.

  ## Variants

  - `new()` - Create empty log
  - `new(entries)` - Create log with entries for replay
  """
  @spec new() :: t()
  @spec new([EffectLogEntry.t()]) :: t()
  def new(arg \\ [])

  # Empty list
  def new([]) do
    %__MODULE__{
      effect_stack: [],
      effect_queue: []
    }
  end

  # List of entries
  def new([%EffectLogEntry{} | _] = entries) do
    %__MODULE__{
      effect_stack: [],
      effect_queue: entries
    }
  end

  @doc """
  Push an entry onto the effect stack.
  """
  @spec push_entry(t(), EffectLogEntry.t()) :: t()
  def push_entry(%__MODULE__{} = log, %EffectLogEntry{} = entry) do
    %{log | effect_stack: [entry | log.effect_stack]}
  end

  @doc """
  Update the most recent entry on the stack.

  Used by wrapped_k to mark an entry as :executed with its value.
  """
  @spec update_head(t(), (EffectLogEntry.t() -> EffectLogEntry.t())) :: t()
  def update_head(%__MODULE__{effect_stack: [head | rest]} = log, update_fn) do
    %{log | effect_stack: [update_fn.(head) | rest]}
  end

  def update_head(%__MODULE__{effect_stack: []} = log, _update_fn), do: log

  @doc """
  Mark an entry as :discarded by its ID.

  Used by leave_scope handlers when a continuation is abandoned.
  Searches the effect_stack for an entry with the given ID and marks it.
  """
  @spec mark_discarded(t(), String.t()) :: t()
  def mark_discarded(%__MODULE__{effect_stack: stack} = log, entry_id) do
    updated_stack =
      Enum.map(stack, fn entry ->
        if entry.id == entry_id do
          EffectLogEntry.set_discarded(entry)
        else
          entry
        end
      end)

    %{log | effect_stack: updated_stack}
  end

  @doc """
  Find an entry by ID in the effect stack.
  """
  @spec find_entry(t(), String.t()) :: EffectLogEntry.t() | nil
  def find_entry(%__MODULE__{effect_stack: stack}, entry_id) do
    Enum.find(stack, fn entry -> entry.id == entry_id end)
  end

  @doc """
  Pop an entry from the effect queue for replay.

  Returns `{entry, updated_log}` or `nil` if queue is empty.
  """
  @spec pop_queue(t()) :: {EffectLogEntry.t(), t()} | nil
  def pop_queue(%__MODULE__{effect_queue: [entry | rest]} = log) do
    {entry, %{log | effect_queue: rest}}
  end

  def pop_queue(%__MODULE__{effect_queue: []}), do: nil

  @doc """
  Check if the effect queue is empty.
  """
  @spec queue_empty?(t()) :: boolean()
  def queue_empty?(%__MODULE__{effect_queue: []}), do: true
  def queue_empty?(%__MODULE__{}), do: false

  @doc """
  Get the head entry from the effect queue without removing it.
  """
  @spec peek_queue(t()) :: EffectLogEntry.t() | nil
  def peek_queue(%__MODULE__{effect_queue: [entry | _]}), do: entry
  def peek_queue(%__MODULE__{effect_queue: []}), do: nil

  @doc """
  Finalize the log after execution completes.

  Moves entries from effect_stack to effect_queue, preparing for future replay.
  Entries are reversed so they're in execution order (oldest first).
  """
  @spec finalize(t()) :: t()
  def finalize(%__MODULE__{} = log) do
    %__MODULE__{
      log
      | effect_stack: [],
        effect_queue: Enum.reverse(log.effect_stack) ++ log.effect_queue
    }
  end

  @doc """
  Enable divergence mode on a log.

  When `allow_divergence?` is true, the logger will accept effects that don't
  match the logged entries. This is used for **rerun** scenarios where
  patched code may take a different path.
  """
  @spec allow_divergence(t()) :: t()
  def allow_divergence(%__MODULE__{} = log) do
    %{log | allow_divergence?: true}
  end

  @doc """
  Get all entries as a list (for inspection/debugging).

  Returns entries in execution order.
  """
  @spec to_list(t()) :: [EffectLogEntry.t()]
  def to_list(%__MODULE__{} = log) do
    Enum.reverse(log.effect_stack) ++ log.effect_queue
  end

  @doc """
  Check if the log contains a root mark (`:__root__`).

  The root mark is lazily inserted on the first intercepted effect.
  """
  @spec has_root_mark?(t()) :: boolean()
  def has_root_mark?(%__MODULE__{} = log) do
    root_id = Skuld.Effects.EffectLogger.root_loop_id()
    effect_logger_sig = Skuld.Effects.EffectLogger

    entries = to_list(log)

    Enum.any?(entries, fn entry ->
      entry.sig == effect_logger_sig and
        match?(%{loop_id: ^root_id}, entry.data)
    end)
  end

  #############################################################################
  ## Loop Hierarchy and Pruning
  #############################################################################

  @typedoc """
  Loop hierarchy mapping: loop_id => parent_loop_id (nil for root loops).
  """
  @type hierarchy :: %{atom() => atom() | nil}

  @doc """
  Build the loop hierarchy from log entries.

  Scans entries in execution order and determines parent-child relationships
  based on nesting order. The first unique loop-id seen is a root (parent = nil).
  Loop-ids seen inside another loop's segment become children.

  ## Example

      # Log with: M1 -> M2 -> M3 -> M3 -> M1 -> M2 -> M3
      hierarchy = Log.build_loop_hierarchy(log)
      # => %{M1 => nil, M2 => M1, M3 => M2}

  """
  @spec build_loop_hierarchy(t()) :: hierarchy()
  def build_loop_hierarchy(%__MODULE__{} = log) do
    entries = to_list(log)

    # Track: {hierarchy_map, active_loop_stack}
    # active_loop_stack is a stack of loop_ids in order of nesting (innermost first)
    {hierarchy, _stack} =
      Enum.reduce(entries, {%{}, []}, fn entry, {hier, stack} ->
        case extract_loop_id(entry) do
          nil ->
            {hier, stack}

          loop_id ->
            if Map.has_key?(hier, loop_id) do
              # Already seen this loop_id - pop stack back to this loop's level
              # (we're starting a new iteration, so inner loops are done)
              new_stack = pop_stack_to(stack, loop_id)
              {hier, new_stack}
            else
              # First time seeing this loop_id
              # Parent is the current innermost loop (head of stack)
              parent = List.first(stack)
              new_hier = Map.put(hier, loop_id, parent)
              new_stack = [loop_id | stack]
              {new_hier, new_stack}
            end
        end
      end)

    hierarchy
  end

  # Pop the stack until we find loop_id, returning stack with loop_id at head
  defp pop_stack_to([], _loop_id), do: []

  defp pop_stack_to([loop_id | _rest] = stack, loop_id), do: stack

  defp pop_stack_to([_other | rest], loop_id), do: pop_stack_to(rest, loop_id)

  @doc """
  Check if `ancestor_id` is an ancestor of `descendant_id` in the hierarchy.

  Returns true if walking up from descendant_id reaches ancestor_id.

  ## Example

      hierarchy = %{M1 => nil, M2 => M1, M3 => M2}
      Log.is_ancestor?(hierarchy, M1, M3)  # => true (M1 <- M2 <- M3)
      Log.is_ancestor?(hierarchy, M3, M1)  # => false
      Log.is_ancestor?(hierarchy, M1, M1)  # => false (not an ancestor of itself)
  """
  @spec is_ancestor?(hierarchy(), atom(), atom()) :: boolean()
  def is_ancestor?(hierarchy, ancestor_id, descendant_id)

  def is_ancestor?(_hierarchy, same, same), do: false

  def is_ancestor?(hierarchy, ancestor_id, descendant_id) do
    case Map.get(hierarchy, descendant_id) do
      nil -> false
      ^ancestor_id -> true
      parent -> is_ancestor?(hierarchy, ancestor_id, parent)
    end
  end

  @doc """
  Get all ancestors of a loop_id (from immediate parent up to root).

  Returns a list of ancestor loop_ids, closest first.

  ## Example

      hierarchy = %{M1 => nil, M2 => M1, M3 => M2}
      Log.ancestors(hierarchy, M3)  # => [M2, M1]
  """
  @spec ancestors(hierarchy(), atom()) :: [atom()]
  def ancestors(hierarchy, loop_id) do
    case Map.get(hierarchy, loop_id) do
      nil -> []
      parent -> [parent | ancestors(hierarchy, parent)]
    end
  end

  @doc """
  Prune completed loop segments, respecting the loop hierarchy.

  For each loop-id, removes all but the last segment (entries since the most
  recent mark). Pruning for a given loop_id stops at marks of ancestor loops,
  preserving the outer loop structure.

  The most recent checkpoint for each loop_id is preserved in `loop_checkpoints`.

  ## Example

      # Before: M1 -> E1 -> M2 -> E2 -> M3 -> E3 -> M3 -> E4 -> M1 -> E5 -> M2 -> E6 -> M3 -> E7
      # After:  M1 -> E5 -> M2 -> E6 -> M3 -> E7
      # (plus checkpoints from the pruned M1, M2, M3 marks)

  """
  @spec prune_completed_loops(t()) :: t()
  def prune_completed_loops(%__MODULE__{} = log) do
    entries = to_list(log)
    hierarchy = build_loop_hierarchy(log)

    # Process entries to find which to keep
    # Strategy: work backwards, keeping track of which loop segments we've seen
    pruned_entries = prune_entries(entries, hierarchy)

    %__MODULE__{
      effect_stack: [],
      effect_queue: pruned_entries,
      allow_divergence?: log.allow_divergence?
    }
  end

  # Prune entries by processing forward and removing completed segments
  defp prune_entries(entries, hierarchy) do
    # Index entries with their positions
    indexed = Enum.with_index(entries)

    # Find all mark positions per loop_id
    marks_by_loop =
      indexed
      |> Enum.filter(fn {entry, _idx} -> extract_loop_id(entry) != nil end)
      |> Enum.group_by(fn {entry, _idx} -> extract_loop_id(entry) end)
      |> Map.new(fn {loop_id, entries_with_idx} ->
        {loop_id, Enum.map(entries_with_idx, fn {_entry, idx} -> idx end)}
      end)

    # For each loop with multiple marks, compute ranges to prune
    # Prune from first mark up to (but not including) the last mark
    # But stop at ancestor marks
    ancestor_sets = compute_ancestor_sets(hierarchy)

    ranges_to_prune =
      Enum.flat_map(marks_by_loop, fn {loop_id, positions} ->
        compute_prune_ranges(loop_id, positions, marks_by_loop, ancestor_sets)
      end)

    # Convert ranges to a set of indices to remove
    indices_to_remove = ranges_to_set(ranges_to_prune)

    # Filter out removed entries
    indexed
    |> Enum.reject(fn {_entry, idx} -> MapSet.member?(indices_to_remove, idx) end)
    |> Enum.map(fn {entry, _idx} -> entry end)
  end

  # Compute ranges to prune for a single loop_id
  # For each pair of consecutive marks, we can prune from mark[i] to mark[i+1]-1
  # But we stop at any ancestor mark
  defp compute_prune_ranges(loop_id, positions, marks_by_loop, ancestor_sets) do
    ancestors = Map.get(ancestor_sets, loop_id, MapSet.new())

    # Find all ancestor mark positions
    ancestor_positions =
      ancestors
      |> Enum.flat_map(fn anc -> Map.get(marks_by_loop, anc, []) end)
      |> MapSet.new()

    # For consecutive marks of this loop_id, prune between them (stopping at ancestors)
    positions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [start_pos, end_pos] ->
      # Prune from start_pos to end_pos-1, but stop at any ancestor mark
      stop_pos = find_stop_position(start_pos, end_pos, ancestor_positions)
      if stop_pos > start_pos, do: [{start_pos, stop_pos - 1}], else: []
    end)
  end

  # Find where to stop pruning - at end_pos or the first ancestor mark, whichever is first
  defp find_stop_position(start_pos, end_pos, ancestor_positions) do
    # Check if any ancestor mark is between start_pos and end_pos
    blocking_ancestor =
      (start_pos + 1)..(end_pos - 1)
      |> Enum.find(fn pos -> MapSet.member?(ancestor_positions, pos) end)

    case blocking_ancestor do
      nil -> end_pos
      pos -> pos
    end
  end

  # Pre-compute ancestor sets for all loop_ids
  defp compute_ancestor_sets(hierarchy) do
    Map.new(hierarchy, fn {loop_id, _parent} ->
      {loop_id, ancestors(hierarchy, loop_id) |> MapSet.new()}
    end)
  end

  # Convert list of {start, end} ranges to a MapSet of all indices
  defp ranges_to_set(ranges) do
    Enum.reduce(ranges, MapSet.new(), fn {start_pos, end_pos}, acc ->
      start_pos..end_pos
      |> Enum.reduce(acc, &MapSet.put(&2, &1))
    end)
  end

  # Extract loop_id from a MarkLoop entry, or nil if not a MarkLoop
  defp extract_loop_id(%EffectLogEntry{sig: sig, data: data}) do
    effect_logger_sig = Skuld.Effects.EffectLogger

    case sig do
      ^effect_logger_sig ->
        case data do
          %{loop_id: loop_id} when is_atom(loop_id) -> loop_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Extract the most recent env_state checkpoint for each loop_id from the log.

  Returns a map of loop_id => env_state (the captured state from the most recent mark).

  ## Example

      checkpoints = Log.extract_loop_checkpoints(log)
      # => %{:__root__ => %{...initial state...}, MyLoop => %{...state at mark...}}
  """
  @spec extract_loop_checkpoints(t()) :: %{atom() => term()}
  def extract_loop_checkpoints(%__MODULE__{} = log) do
    entries = to_list(log)

    # Walk through and keep updating checkpoints (last one wins)
    Enum.reduce(entries, %{}, fn entry, acc ->
      case extract_env_state(entry) do
        nil -> acc
        {loop_id, env_state} -> Map.put(acc, loop_id, env_state)
      end
    end)
  end

  @doc """
  Find the most recent mark entry in the log queue (for cold resume).

  Returns the MarkLoopOp entry with the most recent env_state, or nil.
  """
  @spec find_latest_checkpoint(t()) :: EffectLogEntry.t() | nil
  def find_latest_checkpoint(%__MODULE__{} = log) do
    effect_logger_sig = Skuld.Effects.EffectLogger

    # Look through the queue (entries to replay) for mark entries
    log.effect_queue
    |> Enum.filter(fn entry ->
      entry.sig == effect_logger_sig and match?(%{loop_id: _, env_state: _}, entry.data)
    end)
    |> List.last()
  end

  # Extract {loop_id, env_state} from a MarkLoop entry, or nil
  defp extract_env_state(%EffectLogEntry{sig: sig, data: data}) do
    effect_logger_sig = Skuld.Effects.EffectLogger

    case sig do
      ^effect_logger_sig ->
        case data do
          %{loop_id: loop_id, env_state: env_state} when is_atom(loop_id) ->
            {loop_id, env_state}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Reconstruct Log from decoded JSON map.
  """
  @spec from_json(map()) :: t()
  def from_json(map) when is_map(map) do
    %__MODULE__{
      effect_stack: Enum.map(map["effect_stack"] || [], &EffectLogEntry.from_json/1),
      effect_queue: Enum.map(map["effect_queue"] || [], &EffectLogEntry.from_json/1),
      allow_divergence?: map["allow_divergence?"] || false
    }
  end
end

defimpl Jason.Encoder, for: Skuld.Effects.EffectLogger.Log do
  def encode(value, opts) do
    Jason.Encode.map(
      %{
        effect_stack: value.effect_stack,
        effect_queue: value.effect_queue,
        allow_divergence?: value.allow_divergence?
      },
      opts
    )
  end
end
