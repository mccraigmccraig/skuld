defmodule Skuld.Effects.EffectLogger.EffectLogEntry do
  @moduledoc """
  A flat log entry for an effect invocation.

  Each entry represents a single effect handler invocation and captures:

  - `id` - Unique identifier so wrapped_k can verify it's closing the correct entry
  - `sig` - Effect signature (module)
  - `data` - Effect arguments (the input to the effect)
  - `value` - Result value (if handler called wrapped_k)
  - `state` - Current state in the effect lifecycle

  ## Flat Log Structure

  Entries are stored in a flat list, ordered by when they started. The tree
  structure of the computation is NOT captured - instead, we use `leave_scope`
  handlers to mark entries as `:discarded` when their continuations are
  abandoned (e.g., by a Throw effect).

  ## State Machine

  The `state` field tracks where the effect is in its lifecycle:

  - `:started` - Entry created, handler invoked, continuation not yet completed.
    This includes effects that have suspended (e.g., Yield) - they remain
    `:started` until their continuation is eventually called.

  - `:executed` - Handler called wrapped_k with a value. The `value` field
    contains the result passed to the continuation. Can be short-circuited
    during replay.

  - `:discarded` - Handler discarded the continuation (never called wrapped_k).
    This is the effect that caused the discard (e.g., Throw effect itself).
    Cannot be short-circuited during replay, must re-execute the handler.

  ## State Transitions

      :started → :executed   (wrapped_k called)
      :started → :discarded  (leave_scope triggered before wrapped_k called)

  ## Replay Semantics

  - `:executed` entries can be short-circuited with their logged value
  - `:discarded` entries must re-execute the handler (they caused the discard)
  - `:started` entries indicate suspension points (for cold resume)
  """

  alias Skuld.Comp.SerializableStruct

  @type state :: :started | :executed | :discarded

  @enforce_keys [:id, :sig]
  defstruct [:id, :sig, data: nil, value: nil, state: :started]

  @type t :: %__MODULE__{
          id: String.t(),
          sig: module(),
          data: any(),
          value: any(),
          state: state()
        }

  @doc """
  Create a new effect log entry in `:started` state.
  """
  @spec new(String.t(), module(), any()) :: t()
  def new(id, sig, data) do
    %__MODULE__{
      id: id,
      sig: sig,
      data: data,
      value: nil,
      state: :started
    }
  end

  @doc """
  Set the value and transition to `:executed` state.
  """
  @spec set_executed(t(), any()) :: t()
  def set_executed(%__MODULE__{} = entry, value) do
    %{entry | value: value, state: :executed}
  end

  @doc """
  Transition to `:discarded` state.

  Called by leave_scope when a handler doesn't call wrapped_k (e.g., Throw).
  """
  @spec set_discarded(t()) :: t()
  def set_discarded(%__MODULE__{} = entry) do
    %{entry | state: :discarded}
  end

  @doc """
  Returns true if the entry has completed (handler called wrapped_k).
  """
  @spec completed?(t()) :: boolean()
  def completed?(%__MODULE__{state: :executed}), do: true
  def completed?(%__MODULE__{}), do: false

  @doc """
  Returns true if the entry is in a terminal state.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}) when state in [:executed, :discarded], do: true
  def terminal?(%__MODULE__{}), do: false

  @doc """
  Returns true if the entry can be short-circuited during replay.

  Only `:executed` entries can be short-circuited (they have a value).
  `:discarded` entries must be re-executed.
  """
  @spec can_short_circuit?(t()) :: boolean()
  def can_short_circuit?(%__MODULE__{state: :executed}), do: true
  def can_short_circuit?(%__MODULE__{}), do: false

  @doc """
  Check if this entry matches the given effect signature and data.
  """
  @spec matches?(t(), module(), any()) :: boolean()
  def matches?(%__MODULE__{sig: entry_sig, data: entry_data}, sig, data) do
    entry_sig == sig and entry_data == data
  end

  @doc """
  Reconstruct EffectLogEntry from decoded JSON map.
  """
  @spec from_json(map()) :: t()
  def from_json(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      sig: decode_sig(map["sig"]),
      data: decode_data(map["data"]),
      value: decode_value(map["value"]),
      state: decode_state(map["state"])
    }
  end

  defp decode_sig(nil), do: nil

  defp decode_sig(sig) when is_binary(sig) do
    String.to_existing_atom(sig)
  end

  defp decode_data(nil), do: nil
  defp decode_data(map) when is_map(map), do: SerializableStruct.decode(map)
  defp decode_data(data), do: data

  defp decode_value(nil), do: nil

  defp decode_value(map) when is_map(map) do
    if Map.has_key?(map, "__struct__") do
      SerializableStruct.decode(map)
    else
      map
    end
  end

  defp decode_value(value), do: value

  defp decode_state(nil), do: :started
  defp decode_state("started"), do: :started
  defp decode_state("executed"), do: :executed
  defp decode_state("discarded"), do: :discarded
end

defimpl Jason.Encoder, for: Skuld.Effects.EffectLogger.EffectLogEntry do
  def encode(value, opts) do
    # Validate that effect data is serializable
    if value.data != nil do
      try do
        _ = Jason.encode!(value.data)
      rescue
        e in [Jason.EncodeError, Protocol.UndefinedError] ->
          reraise """
                  Effect data is not JSON serializable.

                  Effect sig: #{inspect(value.sig)}
                  Effect data: #{inspect(value.data, pretty: true)}

                  Effects used with EffectLogger must have serializable data.

                  Original error: #{Exception.message(e)}
                  """,
                  __STACKTRACE__
      end
    end

    Jason.Encode.map(
      %{
        id: value.id,
        sig: value.sig,
        data: value.data,
        value: value.value,
        state: value.state
      },
      opts
    )
  end
end
