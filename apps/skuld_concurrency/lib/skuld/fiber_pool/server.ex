defmodule Skuld.FiberPool.Server do
  @moduledoc """
  An always-on process hosting a FiberPool scheduler with bidirectional message passing.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Coroutine
  alias Skuld.Effects.FiberPool
  alias Skuld.Effects.FiberYield
  alias Skuld.Effects.FreshInt
  alias Skuld.FiberPool.FiberPoolState
  alias Skuld.FiberPool.PendingWork
  alias Skuld.FiberPool.Scheduler

  @type fiber_key :: atom()

  @spec start_link(keyword(Comp.Types.computation())) :: {:ok, pid()}
  def start_link(fibers) when is_list(fibers) do
    parent = self()
    pid = spawn_link(fn -> run_server(parent, fibers) end)
    {:ok, pid}
  end

  @spec resume(pid(), fiber_key(), term()) :: :ok
  def resume(server, fiber_key, value) do
    send(server, {:fiber_resume, fiber_key, value})
    :ok
  end

  @spec cancel(pid(), fiber_key()) :: :ok
  def cancel(server, fiber_key) do
    send(server, {:fiber_cancel, fiber_key})
    :ok
  end

  defp run_server(caller, fibers) do
    wrapped = Enum.map(fibers, fn {key, comp} -> {key, comp} end)

    # Install FiberYield + FiberPool handlers WITHOUT the drain wrapper.
    # FiberPool.with_handler/1 adds a Comp.bind that calls Main.drain_pending
    # on the result, which would run the scheduler before we get control.
    # We want to drive the scheduler ourselves.
    {handles_with_keys, env} =
      boot_computation(wrapped)
      |> FiberYield.with_handler()
      |> FreshInt.with_handler()
      |> Comp.with_handler(Skuld.Effects.FiberPool, FiberPool.handler())
      |> Comp.call(Env.new(), &Comp.identity_k/2)

    id_to_key = Map.new(handles_with_keys, fn {key, handle} -> {handle.id, key} end)
    key_to_id = Map.new(handles_with_keys, fn {key, handle} -> {key, handle.id} end)

    if key_to_id == %{} do
      send(caller, {__MODULE__, :all_done, []})
    else
      pending_work = Env.get_state(env, PendingWork.env_key(), PendingWork.new())
      {pending_fibers, _pending_tasks, _} = PendingWork.take_all(pending_work)

      state = FiberPoolState.new(id: make_ref())

      state =
        Enum.reduce(pending_fibers, state, fn {_fid, f}, acc ->
          {_id, acc} = FiberPoolState.add_fiber(acc, f)
          acc
        end)

      server_loop(caller, id_to_key, key_to_id, state, env)
    end
  end

  defp boot_computation(wrapped) do
    Enum.reduce(wrapped, Comp.pure([]), fn {key, comp}, acc ->
      Comp.bind(acc, fn results ->
        Comp.map(FiberPool.fiber(comp), fn handle ->
          [{key, handle} | results]
        end)
      end)
    end)
  end

  defp server_loop(caller, id_to_key, key_to_id, state, env) do
    state = Scheduler.process_external_wakes(state)
    round = Scheduler.run(state, env)

    cond do
      round.all_done ->
        notify_completions(caller, id_to_key, round.state, round.completions)
        send(caller, {__MODULE__, :all_done, []})

      round.suspended_yields != [] ->
        Enum.each(round.suspended_yields, fn {fiber, _value} ->
          handle_suspended_fiber(caller, id_to_key, round.state, fiber)
        end)

        receive_resume(caller, id_to_key, key_to_id, round.state, env)

      round.batch_ready ->
        server_loop(caller, id_to_key, key_to_id, round.state, env)

      round.waiting_for_tasks ->
        receive_resume(caller, id_to_key, key_to_id, round.state, env)

      true ->
        receive_resume(caller, id_to_key, key_to_id, round.state, env)
    end
  end

  defp handle_suspended_fiber(caller, id_to_key, _state, fiber) do
    case fiber do
      %Coroutine.InternalSuspended{
        id: id,
        suspend: %InternalSuspend{
          payload: %InternalSuspend.FiberYield{value: value}
        }
      } ->
        fiber_key = Map.fetch!(id_to_key, id)
        ipc_suspend = %Comp.ExternalSuspend{value: value, resume: nil, data: nil}
        send(caller, {__MODULE__, fiber_key, ipc_suspend})

      _ ->
        :ok
    end
  end

  defp receive_resume(caller, id_to_key, key_to_id, state, env) do
    receive do
      {:fiber_resume, fiber_key, value} ->
        new_state = inject_wake(state, key_to_id, fiber_key, value)
        server_loop(caller, id_to_key, key_to_id, new_state, env)

      {:fiber_cancel, _fiber_key} ->
        server_loop(caller, id_to_key, key_to_id, state, env)
    end
  end

  defp inject_wake(state, key_to_id, fiber_key, value) do
    case Map.get(key_to_id, fiber_key) do
      nil ->
        state

      fiber_id ->
        wakes = Map.get(state.env_state, :fiber_pool_wakes, [])
        updated = [{fiber_id, value} | wakes]
        FiberPoolState.put_env_state(state, Map.put(state.env_state, :fiber_pool_wakes, updated))
    end
  end

  defp notify_completions(caller, id_to_key, _state, completions) do
    Enum.each(id_to_key, fn {fiber_id, key} ->
      case Map.get(completions, fiber_id) do
        {:ok, result} -> send(caller, {__MODULE__, key, result})
        {:error, error} -> send(caller, {__MODULE__, key, error_to_ipc(error)})
        nil -> :ok
      end
    end)
  end

  defp error_to_ipc(%Coroutine.Error{type: :cancelled, error: r}), do: %Comp.Cancelled{reason: r}
  defp error_to_ipc(%Coroutine.Error{type: :throw, error: e}), do: %Comp.Throw{error: e}
  defp error_to_ipc(other), do: %Comp.Throw{error: other}
end
