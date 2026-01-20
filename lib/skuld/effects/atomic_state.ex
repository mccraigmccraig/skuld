defmodule Skuld.Effects.AtomicState do
  @moduledoc """
  AtomicState effect - thread-safe state for concurrent contexts.

  Unlike the regular State effect which stores state in `env.state` (copied when
  forking to new processes), AtomicState uses external storage (Agent) that can
  be safely accessed from multiple processes.

  Supports both simple single-state usage and multiple independent states via tags.

  ## Handlers

  - `AtomicState.Agent` - Agent-backed handler for production (true atomic ops)
  - `AtomicState.Sync` - State-backed handler for testing (no Agent processes)

  ## Production Usage (Agent handler)

      use Skuld.Syntax
      alias Skuld.Effects.AtomicState

      comp do
        _ <- AtomicState.put(0)
        _ <- AtomicState.modify(&(&1 + 1))
        value <- AtomicState.get()
        value
      end
      |> AtomicState.Agent.with_handler(0)
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
      |> AtomicState.Agent.with_handler(0, tag: :counter)
      |> AtomicState.Agent.with_handler(%{}, tag: :cache)
      |> Comp.run!()
      #=> {1, %{key: "value"}}

  ## Compare-and-Swap (CAS)

      comp do
        _ <- AtomicState.put(10)
        result1 <- AtomicState.cas(10, 20)  # succeeds
        result2 <- AtomicState.cas(10, 30)  # fails - current is 20, not 10
        {result1, result2}
      end
      |> AtomicState.Agent.with_handler(0)
      |> Comp.run!()
      #=> {:ok, {:conflict, 20}}

  ## Testing (Sync handler)

  For testing without spinning up Agents, use the Sync handler:

      comp do
        _ <- AtomicState.put(0)
        _ <- AtomicState.modify(&(&1 + 1))
        AtomicState.get()
      end
      |> AtomicState.Sync.with_handler(0)
      |> Comp.run!()
      #=> 1
  """

  @behaviour Skuld.Comp.IInstall

  import Skuld.Comp.DefOp

  alias Skuld.Comp
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
  ## Handler Installation (Delegating)
  #############################################################################

  @doc """
  Install an Agent-backed AtomicState handler.

  Delegates to `AtomicState.Agent.with_handler/3`.
  """
  @spec with_agent_handler(Types.computation(), term(), keyword()) :: Types.computation()
  defdelegate with_agent_handler(comp, initial, opts \\ []),
    to: __MODULE__.Agent,
    as: :with_handler

  @doc """
  Install a State-backed AtomicState handler for testing.

  Delegates to `AtomicState.Sync.with_handler/3`.
  """
  @spec with_state_handler(Types.computation(), term(), keyword()) :: Types.computation()
  defdelegate with_state_handler(comp, initial, opts \\ []),
    to: __MODULE__.Sync,
    as: :with_handler

  #############################################################################
  ## IInstall Implementation
  #############################################################################

  @doc """
  Install AtomicState handler via catch clause syntax.

  Config selects handler type:

      catch
        AtomicState -> {:agent, 0}                    # agent handler
        AtomicState -> {:agent, {0, tag: :counter}}   # agent with opts
        AtomicState -> {:sync, 0}                     # sync handler
        AtomicState -> {:sync, {0, tag: :counter}}    # sync with opts
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, {:agent, {initial, opts}}) when is_list(opts),
    do: __MODULE__.Agent.with_handler(comp, initial, opts)

  def __handle__(comp, {:agent, initial}),
    do: __MODULE__.Agent.with_handler(comp, initial)

  def __handle__(comp, {:sync, {initial, opts}}) when is_list(opts),
    do: __MODULE__.Sync.with_handler(comp, initial, opts)

  def __handle__(comp, {:sync, initial}),
    do: __MODULE__.Sync.with_handler(comp, initial)

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
