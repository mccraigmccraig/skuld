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
  Create a new empty log.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      effect_stack: [],
      effect_queue: []
    }
  end

  @doc """
  Create a log initialized with entries for replay.
  """
  @spec new([EffectLogEntry.t()]) :: t()
  def new(entries) when is_list(entries) do
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
