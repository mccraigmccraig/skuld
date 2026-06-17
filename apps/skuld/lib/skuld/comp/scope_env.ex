defmodule Skuld.Comp.ScopeEnv do
  @moduledoc """
  Scope machinery carried through a computation.

  Groups the elements that define what scope a computation is running in:

  - `evidence` — installed effect handlers
  - `leave_scope` — cleanup chain for scoped effects
  - `transform_suspend` — suspend decoration chain, also scoped
  - `current_fiber_id` — set when executing inside a FiberPool fiber, nil otherwise

  These are installed together via `scoped/2`, inherited together at fiber
  spawn, and survive suspend/resume cycles together. They are the computation's
  "scope structure" — the runtime context that determines how effects are handled.

  ## Relationship with Env

  `ScopeEnv` is embedded in `Env.scope`. The `Env` module provides accessor
  functions that delegate into `scope` so callers don't need to reach through
  the nesting to read or mutate scope fields directly.
  """

  alias Skuld.Comp.Types

  @type t :: %__MODULE__{
          evidence: %{Types.sig() => Types.handler()},
          leave_scope: Types.leave_scope() | nil,
          transform_suspend: Types.transform_suspend() | nil,
          current_fiber_id: term() | nil
        }

  defstruct evidence: %{},
            leave_scope: nil,
            transform_suspend: nil,
            current_fiber_id: nil

  @doc "Create a fresh scope env with identity leave_scope and transform_suspend"
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc "Set the current fiber ID in scope"
  @spec put_current_fiber_id(t(), term()) :: t()
  def put_current_fiber_id(scope, id) do
    %{scope | current_fiber_id: id}
  end

  @doc "Get the current fiber ID from scope, or nil"
  @spec current_fiber_id(t()) :: term() | nil
  def current_fiber_id(scope) do
    scope.current_fiber_id
  end

  @doc "Install a handler for an effect signature"
  @spec put_handler(t(), Types.sig(), Types.handler()) :: t()
  def put_handler(scope, sig, handler) do
    %{scope | evidence: Map.put(scope.evidence, sig, handler)}
  end

  @doc "Remove a handler for an effect signature"
  @spec delete_handler(t(), Types.sig()) :: t()
  def delete_handler(scope, sig) do
    %{scope | evidence: Map.delete(scope.evidence, sig)}
  end

  @doc "Get the handler for an effect signature, or nil"
  @spec get_handler(t(), Types.sig()) :: Types.handler() | nil
  def get_handler(scope, sig) do
    scope.evidence[sig]
  end

  @doc "Get all installed handler signatures"
  @spec handler_sigs(t()) :: [Types.sig()]
  def handler_sigs(scope) do
    Map.keys(scope.evidence)
  end

  @doc "Install a new leave-scope handler"
  @spec with_leave_scope(t(), Types.leave_scope()) :: t()
  def with_leave_scope(scope, new_leave_scope) do
    %{scope | leave_scope: new_leave_scope}
  end

  @doc "Get the current leave-scope handler (returns identity if nil)"
  @spec get_leave_scope(t()) :: Types.leave_scope()
  def get_leave_scope(scope) do
    scope.leave_scope || fn result, e -> {result, e} end
  end

  @doc "Install a new transform-suspend handler"
  @spec with_transform_suspend(t(), Types.transform_suspend()) :: t()
  def with_transform_suspend(scope, new_transform_suspend) do
    %{scope | transform_suspend: new_transform_suspend}
  end

  @doc "Get the current transform-suspend handler (returns identity if nil)"
  @spec get_transform_suspend(t()) :: Types.transform_suspend()
  def get_transform_suspend(scope) do
    scope.transform_suspend || fn suspend, e -> {suspend, e} end
  end
end
