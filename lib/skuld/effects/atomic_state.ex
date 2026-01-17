defmodule Skuld.Effects.AtomicState do
  @moduledoc """
  AtomicState effect - thread-safe state for concurrent contexts.

  Unlike the regular State effect which stores state in `env.state` (copied when
  forking to new processes), AtomicState uses external storage (Agent) that can
  be safely accessed from multiple processes.

  Supports both simple single-state usage and multiple independent states via tags.

  ## Production Usage (Agent handler)

      use Skuld.Syntax
      alias Skuld.Effects.AtomicState

      comp do
        _ <- AtomicState.put(0)
        _ <- AtomicState.modify(&(&1 + 1))
        value <- AtomicState.get()
        value
      end
      |> AtomicState.with_agent_handler(0)
      |> Comp.run!()
      #=> 1

  ## Multiple States (explicit tags)

      comp do
        _ <- AtomicState.put(:counter, 0)
        _ <- AtomicState.modify(:counter, &(&1 + 1))
        count <- AtomicState.get(:counter)

        _ <- AtomicState.put(:cache, %{})
        _ <- AtomicState.modify(:cache, &Map.put(&1, :key, "value"))
        cache <- AtomicState.get(:cache)

        {count, cache}
      end
      |> AtomicState.with_agent_handler(0, tag: :counter)
      |> AtomicState.with_agent_handler(%{}, tag: :cache)
      |> Comp.run!()
      #=> {1, %{key: "value"}}

  ## Compare-and-Swap (CAS)

      comp do
        _ <- AtomicState.put(10)
        result1 <- AtomicState.cas(10, 20)  # succeeds
        result2 <- AtomicState.cas(10, 30)  # fails - current is 20, not 10
        {result1, result2}
      end
      |> AtomicState.with_agent_handler(0)
      |> Comp.run!()
      #=> {:ok, {:conflict, 20}}

  ## Testing (State handler)

  For testing without spinning up Agents, use `with_state_handler/3` which
  delegates to the regular State effect:

      comp do
        _ <- AtomicState.put(0)
        _ <- AtomicState.modify(&(&1 + 1))
        AtomicState.get()
      end
      |> AtomicState.with_state_handler(0)
      |> State.with_handler(%{})  # State handler for AtomicState's internal state
      |> Comp.run!()
      #=> 1
  """

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  # Tagged signature: each tag gets its own handler key
  defp sig(tag), do: {@sig, tag}

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Get, [:tag], atom_fields: [:tag])
  def_op(Put, [:tag, :value], atom_fields: [:tag])
  def_op(Modify, [:tag, :fun], atom_fields: [:tag])
  def_op(AtomicState, [:tag, :fun], atom_fields: [:tag])
  def_op(Cas, [:tag, :expected, :new], atom_fields: [:tag])

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Atomically read the current state.

  ## Examples

      AtomicState.get()           # use default tag
      AtomicState.get(:counter)   # use explicit tag
  """
  @spec get(atom()) :: Types.computation()
  def get(tag \\ @sig) do
    Comp.effect(sig(tag), %Get{tag: tag})
  end

  @doc """
  Atomically replace the state.

  ## Examples

      AtomicState.put(42)              # use default tag
      AtomicState.put(:counter, 42)    # use explicit tag
  """
  @spec put(term()) :: Types.computation()
  def put(value) do
    Comp.effect(sig(@sig), %Put{tag: @sig, value: value})
  end

  @spec put(atom(), term()) :: Types.computation()
  def put(tag, value) when is_atom(tag) do
    Comp.effect(sig(tag), %Put{tag: tag, value: value})
  end

  @doc """
  Atomically modify the state with a function, returning the new value.

  ## Examples

      AtomicState.modify(&(&1 + 1))              # use default tag
      AtomicState.modify(:counter, &(&1 + 1))    # use explicit tag
  """
  @spec modify((term() -> term())) :: Types.computation()
  def modify(fun) when is_function(fun, 1) do
    Comp.effect(sig(@sig), %Modify{tag: @sig, fun: fun})
  end

  @spec modify(atom(), (term() -> term())) :: Types.computation()
  def modify(tag, fun) when is_atom(tag) and is_function(fun, 1) do
    Comp.effect(sig(tag), %Modify{tag: tag, fun: fun})
  end

  @doc """
  Atomically modify the state with a function that returns `{result, new_state}`.

  Returns the result value.

  ## Examples

      AtomicState.atomic_state(fn s -> {:popped, s - 1} end)
      AtomicState.atomic_state(:counter, fn s -> {s, s + 1} end)
  """
  @spec atomic_state((term() -> {term(), term()})) :: Types.computation()
  def atomic_state(fun) when is_function(fun, 1) do
    Comp.effect(sig(@sig), %AtomicState{tag: @sig, fun: fun})
  end

  @spec atomic_state(atom(), (term() -> {term(), term()})) :: Types.computation()
  def atomic_state(tag, fun) when is_atom(tag) and is_function(fun, 1) do
    Comp.effect(sig(tag), %AtomicState{tag: tag, fun: fun})
  end

  @doc """
  Compare-and-swap: atomically replace state if it equals expected value.

  Returns `:ok` if swap succeeded, `{:conflict, current_value}` if it failed.

  ## Examples

      AtomicState.cas(10, 20)              # if state == 10, set to 20
      AtomicState.cas(:counter, 10, 20)    # with explicit tag
  """
  @spec cas(term(), term()) :: Types.computation()
  def cas(expected, new) do
    Comp.effect(sig(@sig), %Cas{tag: @sig, expected: expected, new: new})
  end

  @spec cas(atom(), term(), term()) :: Types.computation()
  def cas(tag, expected, new) when is_atom(tag) do
    Comp.effect(sig(tag), %Cas{tag: tag, expected: expected, new: new})
  end

  #############################################################################
  ## Agent Handler (Production)
  #############################################################################

  @doc """
  Install an Agent-backed AtomicState handler.

  Creates an Agent process that provides true atomic operations accessible
  from multiple processes. The Agent is stopped when the computation completes.

  ## Options

  - `tag` - the state tag (default: `Skuld.Effects.AtomicState`)

  ## Examples

      # Simple usage
      comp do
        _ <- AtomicState.modify(&(&1 + 1))
        AtomicState.get()
      end
      |> AtomicState.with_agent_handler(0)
      |> Comp.run!()

      # Multiple tagged states
      comp do
        _ <- AtomicState.modify(:a, &(&1 + 1))
        _ <- AtomicState.modify(:b, &(&1 * 2))
        {AtomicState.get(:a), AtomicState.get(:b)}
      end
      |> AtomicState.with_agent_handler(0, tag: :a)
      |> AtomicState.with_agent_handler(10, tag: :b)
      |> Comp.run!()
  """
  @spec with_agent_handler(Types.computation(), term(), keyword()) :: Types.computation()
  def with_agent_handler(comp, initial, opts \\ []) do
    tag = Keyword.get(opts, :tag, @sig)
    agent_key = agent_key(tag)

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
    |> Comp.with_handler(sig(tag), make_agent_handler(tag))
  end

  defp make_agent_handler(tag) do
    fn op, env, k ->
      handle_agent(op, env, k, tag)
    end
  end

  # With tagged signatures, each handler only receives operations for its own tag
  defp handle_agent(%Get{tag: tag}, env, k, tag) do
    agent = Env.get_state(env, agent_key(tag))
    value = Agent.get(agent, & &1)
    k.(value, env)
  end

  defp handle_agent(%Put{tag: tag, value: value}, env, k, tag) do
    agent = Env.get_state(env, agent_key(tag))
    Agent.update(agent, fn _ -> value end)
    k.(:ok, env)
  end

  defp handle_agent(%Modify{tag: tag, fun: fun}, env, k, tag) do
    agent = Env.get_state(env, agent_key(tag))

    new_value =
      Agent.get_and_update(agent, fn v ->
        result = fun.(v)
        {result, result}
      end)

    k.(new_value, env)
  end

  defp handle_agent(%AtomicState{tag: tag, fun: fun}, env, k, tag) do
    agent = Env.get_state(env, agent_key(tag))

    result =
      Agent.get_and_update(agent, fn v ->
        {result, new_state} = fun.(v)
        {result, new_state}
      end)

    k.(result, env)
  end

  defp handle_agent(%Cas{tag: tag, expected: expected, new: new}, env, k, tag) do
    agent = Env.get_state(env, agent_key(tag))

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

  #############################################################################
  ## State Handler (Testing)
  #############################################################################

  @doc """
  Install a State-backed AtomicState handler for testing.

  Maps AtomicState operations to the regular State effect, allowing tests
  without spinning up Agent processes. Operations are "atomic" trivially
  since there's no concurrency in single-process tests.

  Requires a State handler to be installed for the internal state key.

  ## Options

  - `tag` - the state tag (default: `Skuld.Effects.AtomicState`)

  ## Examples

      comp do
        _ <- AtomicState.modify(&(&1 + 1))
        AtomicState.get()
      end
      |> AtomicState.with_state_handler(0)
      |> State.with_handler(%{})  # backing State handler
      |> Comp.run!()
  """
  @spec with_state_handler(Types.computation(), term(), keyword()) :: Types.computation()
  def with_state_handler(comp, initial, opts \\ []) do
    tag = Keyword.get(opts, :tag, @sig)
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)
    state_key = state_key(tag)

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    comp
    |> Comp.with_scoped_state(state_key, initial, scoped_opts)
    |> Comp.with_handler(sig(tag), make_state_handler(tag))
  end

  defp make_state_handler(tag) do
    fn op, env, k ->
      handle_state(op, env, k, tag)
    end
  end

  # With tagged signatures, each handler only receives operations for its own tag
  defp handle_state(%Get{tag: tag}, env, k, tag) do
    value = Env.get_state(env, state_key(tag))
    k.(value, env)
  end

  defp handle_state(%Put{tag: tag, value: value}, env, k, tag) do
    new_env = Env.put_state(env, state_key(tag), value)
    k.(:ok, new_env)
  end

  defp handle_state(%Modify{tag: tag, fun: fun}, env, k, tag) do
    key = state_key(tag)
    current = Env.get_state(env, key)
    new_value = fun.(current)
    new_env = Env.put_state(env, key, new_value)
    k.(new_value, new_env)
  end

  defp handle_state(%AtomicState{tag: tag, fun: fun}, env, k, tag) do
    key = state_key(tag)
    current = Env.get_state(env, key)
    {result, new_state} = fun.(current)
    new_env = Env.put_state(env, key, new_state)
    k.(result, new_env)
  end

  defp handle_state(%Cas{tag: tag, expected: expected, new: new}, env, k, tag) do
    key = state_key(tag)
    current = Env.get_state(env, key)

    if current == expected do
      new_env = Env.put_state(env, key, new)
      k.(:ok, new_env)
    else
      k.({:conflict, current}, env)
    end
  end

  #############################################################################
  ## Key Helpers
  #############################################################################

  @doc """
  Returns the env.state key used for storing the Agent pid for a given tag.
  """
  @spec agent_key(atom()) :: {module(), :agent, atom()}
  def agent_key(tag), do: {@sig, :agent, tag}

  @doc """
  Returns the env.state key used for State-backed storage for a given tag.
  """
  @spec state_key(atom()) :: {module(), :state, atom()}
  def state_key(tag), do: {@sig, :state, tag}
end
