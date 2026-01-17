defmodule Skuld.Comp.Env do
  @moduledoc """
  Environment construction and manipulation.

  The Env struct carries evidence (handlers), state, and the leave-scope chain.
  It supports extension fields - arbitrary atom keys can be added via `Map.put/3`.
  """

  alias Skuld.Comp.Types

  @typedoc """
  The environment struct. Supports extension fields beyond the core struct keys
  (structs are maps, so `Map.put(env, :custom_key, value)` works).
  """
  @type t :: %__MODULE__{
          evidence: %{Types.sig() => Types.handler()},
          state: %{term() => term()},
          leave_scope: Types.leave_scope() | nil,
          transform_suspend: Types.transform_suspend() | nil
        }

  defstruct evidence: %{},
            state: %{},
            leave_scope: nil,
            transform_suspend: nil

  @doc "Create a fresh environment with identity leave-scope and transform-suspend"
  @spec new() :: Skuld.Comp.Types.env()
  def new do
    %__MODULE__{
      leave_scope: fn result, env -> {result, env} end,
      transform_suspend: fn suspend, env -> {suspend, env} end
    }
  end

  @doc "Install a handler for an effect signature"
  @spec with_handler(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig(), Skuld.Comp.Types.handler()) ::
          Skuld.Comp.Types.env()
  def with_handler(env, sig, handler) do
    %{env | evidence: Map.put(env.evidence, sig, handler)}
  end

  @doc "Get handler for an effect signature (raises if missing)"
  @spec get_handler!(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig()) :: Skuld.Comp.Types.handler()
  def get_handler!(env, sig) do
    case env.evidence[sig] do
      nil ->
        available = Map.keys(env.evidence)

        raise ArgumentError, """
        No handler installed for effect: #{inspect(sig)}

        Ensure you've installed a handler before running the computation:
          comp |> SomeEffect.with_handler(initial_state) |> Comp.run()

        Available handlers: #{inspect(available)}
        """

      handler ->
        handler
    end
  end

  @doc "Get handler for an effect signature (returns nil if missing)"
  @spec get_handler(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig()) ::
          Skuld.Comp.Types.handler() | nil
  def get_handler(env, sig) do
    env.evidence[sig]
  end

  @doc "Remove a handler for an effect signature"
  @spec delete_handler(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig()) :: Skuld.Comp.Types.env()
  def delete_handler(env, sig) do
    %{env | evidence: Map.delete(env.evidence, sig)}
  end

  @doc "Update state for an effect"
  @spec put_state(Skuld.Comp.Types.env(), term(), term()) :: Skuld.Comp.Types.env()
  def put_state(env, key, value) do
    %{env | state: Map.put(env.state, key, value)}
  end

  @doc "Get state for an effect"
  @spec get_state(Skuld.Comp.Types.env(), term(), term()) :: term()
  def get_state(env, key, default \\ nil) do
    Map.get(env.state, key, default)
  end

  @doc "Install a new leave-scope handler"
  @spec with_leave_scope(Skuld.Comp.Types.env(), Skuld.Comp.Types.leave_scope()) ::
          Skuld.Comp.Types.env()
  def with_leave_scope(env, new_leave_scope) do
    %{env | leave_scope: new_leave_scope}
  end

  @doc "Get the current leave-scope handler"
  @spec get_leave_scope(Skuld.Comp.Types.env()) :: Skuld.Comp.Types.leave_scope() | nil
  def get_leave_scope(env) do
    env.leave_scope
  end

  @doc "Install a new transform-suspend handler"
  @spec with_transform_suspend(t(), Types.transform_suspend()) :: t()
  def with_transform_suspend(env, new_transform_suspend) do
    %{env | transform_suspend: new_transform_suspend}
  end

  @doc "Get the current transform-suspend handler (returns identity if nil)"
  @spec get_transform_suspend(t()) :: Types.transform_suspend()
  def get_transform_suspend(env) do
    env.transform_suspend || fn suspend, e -> {suspend, e} end
  end
end
