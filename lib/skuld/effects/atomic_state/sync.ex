# Synchronous (State-backed) handler for AtomicState effect.
#
# Maps AtomicState operations to env.state storage, providing a simpler
# implementation for testing without spinning up Agent processes. Operations
# are "atomic" trivially since there's no concurrency in single-process tests.
#
# ## Usage
#
#     comp do
#       _ <- AtomicState.modify(&(&1 + 1))
#       AtomicState.get()
#     end
#     |> AtomicState.Sync.with_handler(0)
#     |> Comp.run!()
#
# ## Multiple Tagged States
#
#     comp do
#       _ <- AtomicState.modify(:a, &(&1 + 1))
#       _ <- AtomicState.modify(:b, &(&1 * 2))
#       {AtomicState.get(:a), AtomicState.get(:b)}
#     end
#     |> AtomicState.Sync.with_handler(0, tag: :a)
#     |> AtomicState.Sync.with_handler(10, tag: :b)
#     |> Comp.run!()
defmodule Skuld.Effects.AtomicState.Sync do
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
  Install a State-backed AtomicState handler.

  ## Options

  - `tag` - the state tag (default: `Skuld.Effects.AtomicState`)
  - `output` - optional output transform function
  - `suspend` - optional suspend transform function
  """
  @spec with_handler(Types.computation(), term(), keyword()) :: Types.computation()
  def with_handler(comp, initial, opts \\ []) do
    tag = Keyword.get(opts, :tag, @default_tag)
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)
    sk = AtomicState.state_key(tag)
    handler_sig = AtomicState.sig(tag)

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    # Op atoms captured for handler closure
    get_op = @get_op
    put_op = @put_op
    modify_op = @modify_op
    atomic_state_op = @atomic_state_op
    cas_op = @cas_op

    handler = fn args, env, k ->
      case args do
        ^get_op ->
          value = Env.get_state!(env, sk)
          k.(value, env)

        {^put_op, value} ->
          new_env = Env.put_state(env, sk, value)
          k.(:ok, new_env)

        {^modify_op, fun} ->
          current = Env.get_state!(env, sk)
          new_value = fun.(current)
          new_env = Env.put_state(env, sk, new_value)
          k.(new_value, new_env)

        {^atomic_state_op, fun} ->
          current = Env.get_state!(env, sk)
          {result, new_state} = fun.(current)
          new_env = Env.put_state(env, sk, new_state)
          k.(result, new_env)

        {^cas_op, expected, new} ->
          current = Env.get_state!(env, sk)

          if current == expected do
            new_env = Env.put_state(env, sk, new)
            k.(:ok, new_env)
          else
            k.({:conflict, current}, env)
          end
      end
    end

    comp
    |> Comp.with_scoped_state(sk, initial, scoped_opts)
    |> Comp.with_handler(handler_sig, handler)
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
  ## IHandle Implementation (default-tag fallback)
  #############################################################################

  @impl Skuld.Comp.IHandle
  def handle(op, env, k) do
    sk = AtomicState.state_key(@default_tag)

    case op do
      @get_op ->
        value = Env.get_state!(env, sk)
        k.(value, env)

      {@put_op, value} ->
        new_env = Env.put_state(env, sk, value)
        k.(:ok, new_env)

      {@modify_op, fun} ->
        current = Env.get_state!(env, sk)
        new_value = fun.(current)
        new_env = Env.put_state(env, sk, new_value)
        k.(new_value, new_env)

      {@atomic_state_op, fun} ->
        current = Env.get_state!(env, sk)
        {result, new_state} = fun.(current)
        new_env = Env.put_state(env, sk, new_state)
        k.(result, new_env)

      {@cas_op, expected, new} ->
        current = Env.get_state!(env, sk)

        if current == expected do
          new_env = Env.put_state(env, sk, new)
          k.(:ok, new_env)
        else
          k.({:conflict, current}, env)
        end
    end
  end
end
