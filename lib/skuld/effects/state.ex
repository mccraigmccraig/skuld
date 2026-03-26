defmodule Skuld.Effects.State do
  @moduledoc """
  State effect - mutable state threaded through computation.

  Supports both simple single-state usage and multiple independent states via tags.

  ## Simple Usage (default tag)

      use Skuld.Syntax
      alias Skuld.Effects.State

      comp do
        n <- State.get()
        _ <- State.put(n + 1)
        n
      end
      |> State.with_handler(0)
      |> Comp.run!()
      #=> 0

  ## Multiple States (explicit tags)

      comp do
        _ <- State.put(:counter, 0)
        _ <- State.modify(:counter, &(&1 + 1))
        count <- State.get(:counter)
        _ <- State.put(:name, "alice")
        name <- State.get(:name)
        {count, name}
      end
      |> State.with_handler(0, tag: :counter)
      |> State.with_handler("", tag: :name)
      |> Comp.run!()
      #=> {1, "alice"}

  ## Per-tag dispatch

  Each tag gets its own handler sig (a module atom) and compact operation
  atoms. The tag is encoded in the sig, not in the operation args, so
  operations carry only the data they need:

  - `get` → `Comp.effect(sig, get_op)` — bare atom, zero allocation
  - `put` → `Comp.effect(sig, {put_op, value})` — minimal 2-tuple
  """

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Data.Change

  @compile {:inline, sig: 1, get_op: 1, put_op: 1, state_key: 1}

  @default_tag __MODULE__

  #############################################################################
  ## Per-tag module-atom construction
  ##
  ## sig(:counter)     => Skuld.Effects.State.Counter
  ## get_op(:counter)  => Skuld.Effects.State.Counter.Get
  ## put_op(:counter)  => Skuld.Effects.State.Counter.Put
  ##
  ## For the default tag (State itself):
  ## sig(State)        => State  (identity — no concat needed)
  ## get_op(State)     => Skuld.Effects.State.Get
  ## put_op(State)     => Skuld.Effects.State.Put
  #############################################################################

  # Pre-compute default tag atoms as module attributes for zero-cost hot path
  @default_sig __MODULE__
  @default_get_op Module.concat(__MODULE__, :Get)
  @default_put_op Module.concat(__MODULE__, :Put)

  @doc "Returns the handler sig atom for a given tag."
  @spec sig(atom()) :: atom()
  def sig(@default_tag), do: @default_sig
  def sig(tag), do: Module.concat(__MODULE__, tag)

  @doc "Returns the get operation atom for a given tag."
  @spec get_op(atom()) :: atom()
  def get_op(tag \\ @default_tag)
  def get_op(@default_tag), do: @default_get_op
  def get_op(tag), do: Module.concat(sig(tag), :Get)

  @doc "Returns the put operation atom for a given tag."
  @spec put_op(atom()) :: atom()
  def put_op(tag \\ @default_tag)
  def put_op(@default_tag), do: @default_put_op
  def put_op(tag), do: Module.concat(sig(tag), :Put)

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Get the current state.

  ## Examples

      State.get()           # use default tag
      State.get(:counter)   # use explicit tag
  """
  @spec get(atom()) :: Types.computation()
  def get(tag \\ @default_tag) do
    Comp.effect(sig(tag), get_op(tag))
  end

  @doc """
  Replace the state, returning `%Change{old: old_state, new: new_state}`.

  ## Examples

      State.put(42)              # use default tag
      State.put(:counter, 42)    # use explicit tag
  """
  @spec put(term()) :: Types.computation()
  def put(value) do
    Comp.effect(@default_sig, {@default_put_op, value})
  end

  @spec put(atom(), term()) :: Types.computation()
  def put(tag, value) when is_atom(tag) do
    Comp.effect(sig(tag), {put_op(tag), value})
  end

  @doc """
  Modify the state with a function, returning the old value.

  ## Examples

      State.modify(&(&1 + 1))              # use default tag
      State.modify(:counter, &(&1 + 1))    # use explicit tag
  """
  @spec modify((term() -> term())) :: Types.computation()
  def modify(f) when is_function(f, 1) do
    modify(@default_tag, f)
  end

  @spec modify(atom(), (term() -> term())) :: Types.computation()
  def modify(tag, f) when is_atom(tag) and is_function(f, 1) do
    Comp.bind(get(tag), fn old ->
      Comp.bind(put(tag, f.(old)), fn _ ->
        Comp.pure(old)
      end)
    end)
  end

  @doc """
  Get a value derived from the state.

  ## Examples

      State.gets(&Map.get(&1, :name))              # use default tag
      State.gets(:user, &Map.get(&1, :name))       # use explicit tag
  """
  @spec gets((term() -> term())) :: Types.computation()
  def gets(f) when is_function(f, 1) do
    gets(@default_tag, f)
  end

  @spec gets(atom(), (term() -> term())) :: Types.computation()
  def gets(tag, f) when is_atom(tag) and is_function(f, 1) do
    Comp.map(get(tag), f)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped State handler for a computation.

  ## Options

  - `tag` - the state tag (default: `Skuld.Effects.State`)
  - `output` - optional function `(result, final_state) -> new_result`
    to transform the result before returning.

  ## Examples

      # Simple usage with default tag
      comp do
        x <- State.get()
        _ <- State.put(x + 1)
        x
      end
      |> State.with_handler(0)
      |> Comp.run!()
      #=> 0

      # With explicit tag
      comp do
        x <- State.get(:counter)
        _ <- State.put(:counter, x + 1)
        x
      end
      |> State.with_handler(0, tag: :counter)
      |> Comp.run!()
      #=> 0

      # Include final state in result
      comp do
        _ <- State.modify(&(&1 + 1))
        :done
      end
      |> State.with_handler(5, output: fn result, state -> {result, state} end)
      |> Comp.run!()
      #=> {:done, 6}

      # Multiple states
      comp do
        a <- State.get(:a)
        b <- State.get(:b)
        {a, b}
      end
      |> State.with_handler(1, tag: :a)
      |> State.with_handler(2, tag: :b)
      |> Comp.run!()
      #=> {1, 2}
  """
  @spec with_handler(Types.computation(), term(), keyword()) :: Types.computation()
  def with_handler(comp, initial, opts \\ []) do
    tag = Keyword.get(opts, :tag, @default_tag)
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)
    handler_sig = sig(tag)
    sk = state_key(tag)

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    # Build handler that closes over state_key and op atoms
    tag_get_op = get_op(tag)
    tag_put_op = put_op(tag)

    handler = fn args, env, k ->
      case args do
        ^tag_get_op ->
          value = Env.get_state!(env, sk)
          k.(value, env)

        {^tag_put_op, value} ->
          old_value = Env.get_state!(env, sk)
          new_env = Env.put_state(env, sk, value)
          k.(Change.new(old_value, value), new_env)
      end
    end

    comp
    |> Comp.with_scoped_state(sk, initial, scoped_opts)
    |> Comp.with_handler(handler_sig, handler)
  end

  @doc """
  Install State handler via catch clause syntax.

  Accepts either `initial` or `{initial, opts}`:

      catch
        State -> 0                          # initial value
        State -> {0, output: fn r, s -> {r, s} end}  # with opts
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, {initial, opts}) when is_list(opts), do: with_handler(comp, initial, opts)
  def __handle__(comp, initial), do: with_handler(comp, initial)

  @doc "Extract the state for the given tag from an env"
  @spec get_state(Types.env(), atom()) :: term()
  def get_state(env, tag \\ @default_tag) do
    Env.get_state(env, state_key(tag))
  end

  #############################################################################
  ## IHandle Implementation (kept for IHandle contract — handler closures
  ## are used directly in with_handler, but this satisfies the behaviour)
  #############################################################################

  @impl Skuld.Comp.IHandle
  def handle(@default_get_op, env, k) do
    value = Env.get_state!(env, state_key(@default_tag))
    k.(value, env)
  end

  @impl Skuld.Comp.IHandle
  def handle({@default_put_op, value}, env, k) do
    key = state_key(@default_tag)
    old_value = Env.get_state!(env, key)
    new_env = Env.put_state(env, key, value)
    k.(Change.new(old_value, value), new_env)
  end

  #############################################################################
  ## State Key Helper
  #############################################################################

  @doc """
  Returns the env.state key used for a given tag.

  Useful for configuring EffectLogger's `state_keys` filter.

  ## Examples

      # Only capture State effect data in EffectLogger snapshots
      EffectLogger.with_logging(state_keys: [State.state_key(MyApp.Counter)])

      # Multiple states
      EffectLogger.with_logging(state_keys: [
        State.state_key(:counter),
        State.state_key(:user)
      ])
  """
  @spec state_key(atom()) :: {module(), atom()}
  def state_key(tag), do: {__MODULE__, tag}
end
