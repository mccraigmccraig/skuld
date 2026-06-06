defimpl Skuld.Comp.ISentinel, for: Skuld.Comp.InternalSuspend do
  alias Skuld.Comp.InternalSuspend.Await
  alias Skuld.Comp.InternalSuspend.Batch
  alias Skuld.Comp.InternalSuspend.Channel

  def run(suspend, env) do
    {drained, drained_env} = Skuld.FiberPool.Main.drain_pending(suspend, env)
    Skuld.Comp.ISentinel.run(drained, drained_env)
  end

  def run!(_suspend) do
    raise "InternalSuspend must be handled by a scheduler"
  end

  def sentinel?(_), do: true
  def suspend?(_), do: true
  def error?(_), do: false

  def serializable_payload(%{payload: %Batch{batch_key: batch_key, op: op, request_id: id}}) do
    %{type: :batch, batch_key: batch_key, op: op, request_id: id}
  end

  def serializable_payload(%{payload: %Channel{channel_id: ch_id, operation: op, item: item}}) do
    %{type: :channel, channel_id: ch_id, operation: op, item: item}
  end

  def serializable_payload(%{payload: %Await{handles: handles, mode: mode}}) do
    %{type: :await, handle_ids: Enum.map(handles, & &1.id), mode: mode}
  end
end
