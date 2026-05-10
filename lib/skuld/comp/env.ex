defmodule Skuld.Comp.Env do
  @moduledoc """
  Environment construction and manipulation.

  The Env struct carries scope (handlers, leave-scope, transform-suspend)
  and effect state. Scope is embedded as a `ScopeEnv` sub-struct — mutate
  through `Env.*` functions rather than reaching into `env.scope` directly.

  ## Effect State

  Effect state lives exclusively in `env.state` via `put_state/3` and
  `get_state/2,3`. This map is the only state bucket that survives across
  fiber suspend/resume cycles — the scheduler threads `env.state` through
  all fibers in a pool.

  Do **not** add arbitrary top-level keys to the `%Env{}` struct itself.
  Such keys will be lost during fiber execution because the scheduler only
  preserves `scope` and `state` fields. Use `put_state/3` for any value
  that needs to survive across suspensions.
  """

  alias Skuld.Comp.ScopeEnv
  alias Skuld.Comp.Types

  @compile {:inline,
            get_state!: 2,
            get_state: 2,
            get_state: 3,
            put_state: 3,
            get_handler!: 2,
            get_handler: 2,
            with_handler: 3,
            delete_handler: 2,
            handler_sigs: 1,
            with_leave_scope: 2,
            get_leave_scope: 1,
            run_leave_scope: 2,
            with_transform_suspend: 2,
            get_transform_suspend: 1,
            get_scope: 1,
            with_scope: 2}

  @typedoc """
  The environment struct.

  ## Fields

  - `scope` — scope machinery (evidence, leave_scope, transform_suspend)
  - `state` — effect state (Writer accumulators, channel state, etc.)
  """
  @type t :: %__MODULE__{
          scope: ScopeEnv.t(),
          state: %{term() => term()}
        }

  defstruct scope: ScopeEnv.new(),
            state: %{}

  @doc "Create a fresh environment with identity leave-scope and transform-suspend"
  @spec new() :: Skuld.Comp.Types.env()
  def new do
    %__MODULE__{
      scope: %ScopeEnv{
        leave_scope: fn result, env -> {result, env} end,
        transform_suspend: fn suspend, env -> {suspend, env} end
      }
    }
  end

  @doc "Install a handler for an effect signature"
  @spec with_handler(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig(), Skuld.Comp.Types.handler()) ::
          Skuld.Comp.Types.env()
  def with_handler(env, sig, handler) do
    %{env | scope: ScopeEnv.put_handler(env.scope, sig, handler)}
  end

  @doc "Get handler for an effect signature (raises if missing)"
  @spec get_handler!(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig()) :: Skuld.Comp.Types.handler()
  def get_handler!(env, sig) do
    case ScopeEnv.get_handler(env.scope, sig) do
      nil ->
        available = ScopeEnv.handler_sigs(env.scope)

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
    ScopeEnv.get_handler(env.scope, sig)
  end

  @doc "Remove a handler for an effect signature"
  @spec delete_handler(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig()) :: Skuld.Comp.Types.env()
  def delete_handler(env, sig) do
    %{env | scope: ScopeEnv.delete_handler(env.scope, sig)}
  end

  @doc "Get all installed handler signatures"
  @spec handler_sigs(Skuld.Comp.Types.env()) :: [Skuld.Comp.Types.sig()]
  def handler_sigs(env) do
    ScopeEnv.handler_sigs(env.scope)
  end

  @doc """
  Update state for an effect.

  Effect state lives in `env.state` — the only map that survives across
  fiber suspend/resume cycles. Use module-specific keys (e.g. module attributes
  or struct-based keys) to avoid collisions between effects.

  See the moduledoc for guidance on what belongs in `state` vs on the `Env`
  struct directly.
  """
  @spec put_state(Skuld.Comp.Types.env(), term(), term()) :: Skuld.Comp.Types.env()
  def put_state(env, key, value) do
    %{env | state: Map.put(env.state, key, value)}
  end

  @doc "Get state for an effect"
  @spec get_state(Skuld.Comp.Types.env(), term(), term()) :: term()
  def get_state(env, key, default \\ nil) do
    Map.get(env.state, key, default)
  end

  @doc "Get state for an effect, raising if the key is not present (use-after-cleanup guard)"
  @spec get_state!(Skuld.Comp.Types.env(), term()) :: term()
  def get_state!(env, key) do
    case Map.fetch(env.state, key) do
      {:ok, value} ->
        value

      :error ->
        raise "Effect state not found for key #{inspect(key)} — effect used outside its handler scope"
    end
  end

  @doc "Install a new leave-scope handler"
  @spec with_leave_scope(Skuld.Comp.Types.env(), Skuld.Comp.Types.leave_scope()) ::
          Skuld.Comp.Types.env()
  def with_leave_scope(env, new_leave_scope) do
    %{env | scope: ScopeEnv.with_leave_scope(env.scope, new_leave_scope)}
  end

  @doc "Get the current leave-scope handler (returns identity if nil)"
  @spec get_leave_scope(Skuld.Comp.Types.env()) :: Skuld.Comp.Types.leave_scope()
  def get_leave_scope(env) do
    ScopeEnv.get_leave_scope(env.scope)
  end

  @doc "Run the leave-scope chain on a result"
  @spec run_leave_scope(Skuld.Comp.Types.env(), term()) ::
          {Skuld.Comp.Types.result(), Skuld.Comp.Types.env()}
  def run_leave_scope(env, result) do
    get_leave_scope(env).(result, env)
  end

  @doc "Install a new transform-suspend handler"
  @spec with_transform_suspend(t(), Types.transform_suspend()) :: t()
  def with_transform_suspend(env, new_transform_suspend) do
    %{env | scope: ScopeEnv.with_transform_suspend(env.scope, new_transform_suspend)}
  end

  @doc "Get the current transform-suspend handler (returns identity if nil)"
  @spec get_transform_suspend(t()) :: Types.transform_suspend()
  def get_transform_suspend(env) do
    ScopeEnv.get_transform_suspend(env.scope)
  end

  @doc "Get the scope sub-struct (for inspection)"
  @spec get_scope(t()) :: ScopeEnv.t()
  def get_scope(env) do
    env.scope
  end

  @doc "Replace the scope sub-struct (for initial construction; prefer with_* functions for mutation)"
  @spec with_scope(t(), ScopeEnv.t()) :: t()
  def with_scope(env, scope) do
    %{env | scope: scope}
  end
end
