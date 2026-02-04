# Agent-backed handler for AtomicState effect.
#
# Creates an Agent process that provides true atomic operations accessible
# from multiple processes. The Agent is stopped when the computation completes.
#
# ## Usage
#
#     comp do
#       _ <- AtomicState.modify(&(&1 + 1))
#       AtomicState.get()
#     end
#     |> AtomicState.Agent.with_handler(0)
#     |> Comp.run!()
#
# ## Multiple Tagged States
#
#     comp do
#       _ <- AtomicState.modify(:a, &(&1 + 1))
#       _ <- AtomicState.modify(:b, &(&1 * 2))
#       {AtomicState.get(:a), AtomicState.get(:b)}
#     end
#     |> AtomicState.Agent.with_handler(0, tag: :a)
#     |> AtomicState.Agent.with_handler(10, tag: :b)
#     |> Comp.run!()
defmodule Skuld.Effects.AtomicState.Agent do
  @moduledoc false

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Effects.AtomicState

  @sig AtomicState

  defp sig(tag), do: {@sig, tag}

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install an Agent-backed AtomicState handler.

  ## Options

  - `tag` - the state tag (default: `Skuld.Effects.AtomicState`)
  """
  @spec with_handler(Types.computation(), term(), keyword()) :: Types.computation()
  def with_handler(comp, initial, opts \\ []) do
    tag = Keyword.get(opts, :tag, @sig)
    agent_key = AtomicState.agent_key(tag)

    comp
    |> Comp.scoped(fn env ->
      {:ok, agent} = Agent.start_link(fn -> initial end)

      # Store agent pid in env.state so handler can find it
      modified = Env.put_state(env, agent_key, agent)

      finally_k = fn value, e ->
        # Stop the agent
        agent_pid = Env.get_state(e, agent_key)
        if agent_pid, do: Agent.stop(agent_pid)

        # Clean up env.state
        restored_env = %{e | state: Map.delete(e.state, agent_key)}
        {value, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(sig(tag), &__MODULE__.handle/3)
  end

  #############################################################################
  ## IInstall Implementation
  #############################################################################

  @doc """
  Install handler via catch clause syntax.

      catch
        AtomicState.Agent -> 0
        AtomicState.Agent -> {0, tag: :counter}
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, {initial, opts}) when is_list(opts), do: with_handler(comp, initial, opts)
  def __handle__(comp, initial), do: with_handler(comp, initial)

  #############################################################################
  ## IHandle Implementation
  #############################################################################

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.Get{tag: tag}, env, k) do
    agent = Env.get_state(env, AtomicState.agent_key(tag))
    value = Agent.get(agent, & &1)
    k.(value, env)
  end

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.Put{tag: tag, value: value}, env, k) do
    agent = Env.get_state(env, AtomicState.agent_key(tag))
    Agent.update(agent, fn _ -> value end)
    k.(:ok, env)
  end

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.Modify{tag: tag, fun: fun}, env, k) do
    agent = Env.get_state(env, AtomicState.agent_key(tag))

    new_value =
      Agent.get_and_update(agent, fn v ->
        result = fun.(v)
        {result, result}
      end)

    k.(new_value, env)
  end

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.AtomicState{tag: tag, fun: fun}, env, k) do
    agent = Env.get_state(env, AtomicState.agent_key(tag))

    result =
      Agent.get_and_update(agent, fn v ->
        {result, new_state} = fun.(v)
        {result, new_state}
      end)

    k.(result, env)
  end

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.Cas{tag: tag, expected: expected, new: new}, env, k) do
    agent = Env.get_state(env, AtomicState.agent_key(tag))

    result =
      Agent.get_and_update(agent, fn current ->
        if current == expected do
          {:ok, new}
        else
          {{:conflict, current}, current}
        end
      end)

    k.(result, env)
  end
end
