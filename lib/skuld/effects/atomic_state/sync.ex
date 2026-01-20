defmodule Skuld.Effects.AtomicState.Sync do
  @moduledoc """
  Synchronous (State-backed) handler for AtomicState effect.

  Maps AtomicState operations to env.state storage, providing a simpler
  implementation for testing without spinning up Agent processes. Operations
  are "atomic" trivially since there's no concurrency in single-process tests.

  ## Usage

      comp do
        _ <- AtomicState.modify(&(&1 + 1))
        AtomicState.get()
      end
      |> AtomicState.Sync.with_handler(0)
      |> Comp.run!()

  ## Multiple Tagged States

      comp do
        _ <- AtomicState.modify(:a, &(&1 + 1))
        _ <- AtomicState.modify(:b, &(&1 * 2))
        {AtomicState.get(:a), AtomicState.get(:b)}
      end
      |> AtomicState.Sync.with_handler(0, tag: :a)
      |> AtomicState.Sync.with_handler(10, tag: :b)
      |> Comp.run!()
  """

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
  Install a State-backed AtomicState handler.

  ## Options

  - `tag` - the state tag (default: `Skuld.Effects.AtomicState`)
  - `output` - optional output transform function
  - `suspend` - optional suspend transform function
  """
  @spec with_handler(Types.computation(), term(), keyword()) :: Types.computation()
  def with_handler(comp, initial, opts \\ []) do
    tag = Keyword.get(opts, :tag, @sig)
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)
    state_key = AtomicState.state_key(tag)

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    comp
    |> Comp.with_scoped_state(state_key, initial, scoped_opts)
    |> Comp.with_handler(sig(tag), &__MODULE__.handle/3)
  end

  #############################################################################
  ## IInstall Implementation
  #############################################################################

  @doc """
  Install handler via catch clause syntax.

      catch
        AtomicState.Sync -> 0
        AtomicState.Sync -> {0, tag: :counter}
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, {initial, opts}) when is_list(opts), do: with_handler(comp, initial, opts)
  def __handle__(comp, initial), do: with_handler(comp, initial)

  #############################################################################
  ## IHandle Implementation
  #############################################################################

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.Get{tag: tag}, env, k) do
    value = Env.get_state(env, AtomicState.state_key(tag))
    k.(value, env)
  end

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.Put{tag: tag, value: value}, env, k) do
    new_env = Env.put_state(env, AtomicState.state_key(tag), value)
    k.(:ok, new_env)
  end

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.Modify{tag: tag, fun: fun}, env, k) do
    key = AtomicState.state_key(tag)
    current = Env.get_state(env, key)
    new_value = fun.(current)
    new_env = Env.put_state(env, key, new_value)
    k.(new_value, new_env)
  end

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.AtomicState{tag: tag, fun: fun}, env, k) do
    key = AtomicState.state_key(tag)
    current = Env.get_state(env, key)
    {result, new_state} = fun.(current)
    new_env = Env.put_state(env, key, new_state)
    k.(result, new_env)
  end

  @impl Skuld.Comp.IHandle
  def handle(%AtomicState.Cas{tag: tag, expected: expected, new: new}, env, k) do
    key = AtomicState.state_key(tag)
    current = Env.get_state(env, key)

    if current == expected do
      new_env = Env.put_state(env, key, new)
      k.(:ok, new_env)
    else
      k.({:conflict, current}, env)
    end
  end
end
