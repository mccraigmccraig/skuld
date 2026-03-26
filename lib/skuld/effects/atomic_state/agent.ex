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

  @default_tag AtomicState

  # Op atoms from parent effect
  @get_op AtomicState.get_op()
  @put_op AtomicState.put_op()
  @modify_op AtomicState.modify_op()
  @atomic_state_op AtomicState.atomic_state_op()
  @cas_op AtomicState.cas_op()

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
    tag = Keyword.get(opts, :tag, @default_tag)
    agent_key = AtomicState.agent_key(tag)
    handler_sig = AtomicState.sig(tag)

    # Op atoms captured for handler closure
    get_op = @get_op
    put_op = @put_op
    modify_op = @modify_op
    atomic_state_op = @atomic_state_op
    cas_op = @cas_op

    handler = fn args, env, k ->
      case args do
        ^get_op ->
          agent = Env.get_state!(env, agent_key)
          value = Agent.get(agent, & &1)
          k.(value, env)

        {^put_op, value} ->
          agent = Env.get_state!(env, agent_key)
          Agent.update(agent, fn _ -> value end)
          k.(:ok, env)

        {^modify_op, fun} ->
          agent = Env.get_state!(env, agent_key)

          new_value =
            Agent.get_and_update(agent, fn v ->
              result = fun.(v)
              {result, result}
            end)

          k.(new_value, env)

        {^atomic_state_op, fun} ->
          agent = Env.get_state!(env, agent_key)

          result =
            Agent.get_and_update(agent, fn v ->
              {result, new_state} = fun.(v)
              {result, new_state}
            end)

          k.(result, env)

        {^cas_op, expected, new} ->
          agent = Env.get_state!(env, agent_key)

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
    |> Comp.with_handler(handler_sig, handler)
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
  ## IHandle Implementation (default-tag fallback)
  #############################################################################

  @impl Skuld.Comp.IHandle
  def handle(op, env, k) do
    agent_key = AtomicState.agent_key(@default_tag)

    case op do
      @get_op ->
        agent = Env.get_state!(env, agent_key)
        value = Agent.get(agent, & &1)
        k.(value, env)

      {@put_op, value} ->
        agent = Env.get_state!(env, agent_key)
        Agent.update(agent, fn _ -> value end)
        k.(:ok, env)

      {@modify_op, fun} ->
        agent = Env.get_state!(env, agent_key)

        new_value =
          Agent.get_and_update(agent, fn v ->
            result = fun.(v)
            {result, result}
          end)

        k.(new_value, env)

      {@atomic_state_op, fun} ->
        agent = Env.get_state!(env, agent_key)

        result =
          Agent.get_and_update(agent, fn v ->
            {result, new_state} = fun.(v)
            {result, new_state}
          end)

        k.(result, env)

      {@cas_op, expected, new} ->
        agent = Env.get_state!(env, agent_key)

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
end
