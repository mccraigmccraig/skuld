defprotocol Skuld.Comp.ISentinel do
  @moduledoc """
  Protocol for handling sentinel values in run/run! and generic sentinel inspection.

  Sentinels are control flow values (Suspend, Throw, etc.) that bypass normal
  computation flow. This protocol allows generic handling without coupling to
  specific sentinel types.

  ## Sentinel Categories

  Sentinels fall into two categories:

  - **Suspend sentinels** (`suspend?/1` returns true): ExternalSuspend, InternalSuspend
    These represent suspended computations that can be resumed.

  - **Error sentinels** (`error?/1` returns true): Throw, Cancelled
    These represent error conditions that propagate up the call stack.

  Plain values have `sentinel?/1`, `suspend?/1`, and `error?/1` all return false.
  """
  @fallback_to_any true

  @doc "Complete a computation result - invoke leave_scope or bypass for sentinels"
  @spec run(t, Skuld.Comp.Types.env()) :: {Skuld.Comp.Types.result(), Skuld.Comp.Types.env()}
  def run(result, env)

  @doc "Extract value or raise for sentinel types"
  @spec run!(t) :: term()
  def run!(value)

  @doc "Is this a sentinel value? Returns false for plain values."
  @spec sentinel?(t) :: boolean()
  def sentinel?(value)

  @doc "Is this a suspend sentinel (ExternalSuspend, InternalSuspend)?"
  @spec suspend?(t) :: boolean()
  def suspend?(value)

  @doc "Is this an error sentinel (Throw, Cancelled)?"
  @spec error?(t) :: boolean()
  def error?(value)

  @doc "Get the serializable payload (struct fields minus :resume). Used for logging/serialization."
  @spec serializable_payload(t) :: map()
  def serializable_payload(sentinel)
end

defimpl Skuld.Comp.ISentinel, for: Any do
  def run(result, env), do: env.leave_scope.(result, env)
  def run!(value), do: value
  def sentinel?(_value), do: false
  def suspend?(_value), do: false
  def error?(_value), do: false
  def serializable_payload(_value), do: %{}
end
