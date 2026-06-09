defmodule Skuld.Coroutine do
  @moduledoc """
  Cooperative fiber primitive for the FiberPool scheduler.

  Part of the `skuld_concurrency` package, which provides cooperative
  coroutines, the FiberPool scheduler, Channel/Brook streaming, and
  AsyncCoroutine process bridging. See the
  [architecture guide](https://hexdocs.pm/skuld/architecture.html)
  for how these fit into the Skuld ecosystem.

  A Fiber wraps a computation that can be run incrementally, suspended when it
  yields, and resumed with a value. This is the fundamental building block for
  cooperative concurrency in Skuld.

  ## Sum Type

  A fiber is always exactly one of these states — no `status` atom, no nil fields:

  - `%Coroutine.Pending{id, computation, env}` — ready to start
  - `%Coroutine.InternalSuspended{id, k, suspend, env}` — suspended, needs scheduler
  - `%Coroutine.ExternalSuspended{id, k, env}` — suspended, external callback
  - `%Coroutine.ForeignSuspended{id, suspend, env}` — suspended on foreign resource
  - `%Coroutine.ForeignSuspensions{id, suspensions, env, resume}` — bundled foreign suspensions
  - `%Coroutine.Completed{id, result, env}` — finished successfully
  - `%Coroutine.Errored{id, error, env}` — finished with error
  - `%Coroutine.Cancelled{id, reason, env}` — cancelled before completion

  ## Two entry points: `call` vs `run`

  Following `Comp.call`/`Comp.run` convention:

  - `call/1,2` — raw step, no `ISentinel.run`. Returns typed states directly.
    For use inside the FiberPool scheduler, which applies `ISentinel.run`
    at its own boundary.
  - `run/1,2` — step + `ISentinel.run`. Applies `transform_suspend` and
    `leave_scope` before returning typed states. For standalone use
    (AsyncCoroutine, SerializableCoroutine, etc.).

  ## Lifecycle

  1. Create with `new/2` — returns `%Pending{}`
   2. Step with `call/1` or `run/1` — returns `%Completed{}`, `%InternalSuspended{}`,
      `%ExternalSuspended{}`, `%ForeignSuspended{}`, or `%Errored{}`
   3. Resume with `call/2` or `run/2` — match on `%InternalSuspended{}`,
      `%ExternalSuspended{}`, or `%ForeignSuspended{}`, pass the resume value.
      `%ForeignSuspensions{}` accepts `%{id => value}` for batch resumption.
  4. Cancel with `cancel/2` — invokes leave_scope cleanup, returns `%Cancelled{}`

  ## Example (standalone, with `run`)

      fiber
      |> Coroutine.new(comp, env)
      |> Coroutine.run()
      |> Coroutine.run(result1)
      |> Coroutine.run(result2)
      |> Coroutine.cancel()
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.ISentinel
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Comp.Types
  alias Skuld.Coroutine.Cancelled
  alias Skuld.Coroutine.Completed
  alias Skuld.Coroutine.Error
  alias Skuld.Coroutine.Errored
  alias Skuld.Coroutine.ExternalSuspended
  alias Skuld.Coroutine.ForeignSuspended
  alias Skuld.Coroutine.ForeignSuspensions
  alias Skuld.Coroutine.InternalSuspended
  alias Skuld.Coroutine.Pending

  @typedoc """
  A fiber in any state.

  Callers pattern-match on the struct name to determine state:
  `%Pending{}`, `%InternalSuspended{}`, `%ExternalSuspended{}`,
  `%ForeignSuspended{}`, `%ForeignSuspensions{}`, `%Completed{}`, `%Errored{}`, `%Cancelled{}`.
  """
  @type t ::
          Pending.t()
          | InternalSuspended.t()
          | ExternalSuspended.t()
          | ForeignSuspended.t()
          | ForeignSuspensions.t()
          | Completed.t()
          | Errored.t()
          | Cancelled.t()

  @doc """
  Create a new fiber from a computation.

  The fiber starts as `%Pending{}` with the computation and env stored,
  ready to be run with `run/1` or `call/1`.

  ## Parameters

  - `comp` - The computation to run as a fiber
  - `env` - The environment to run in (typically inherited from parent)

  ## Example

      fiber = Coroutine.new(my_comp, env)
      assert match?(%Coroutine.Pending{}, fiber)
  """
  @spec new(Types.computation(), Types.env(), keyword()) :: Pending.t()
  def new(comp, env, opts \\ []) do
    %Pending{
      id: Keyword.get(opts, :id),
      computation: comp,
      env: env
    }
  end

  @doc """
  Step a pending fiber, or resume a suspended fiber with a value.

  Clauses dispatch on the fiber's sum-type state:

  - `%Pending{}` — starts the computation, returns the fiber in its new state
  - `%InternalSuspended{}` — resumes with `value`, returns the fiber in its new state
  - `%ExternalSuspended{}` — resumes with `value`, returns the fiber in its new state

  Returns one of: `%Completed{}`, `%InternalSuspended{}`, `%ExternalSuspended{}`,
  or `%Errored{}`. Raises for terminal or invalid states.

  ## Examples

      fiber = Coroutine.new(my_comp, env)
      fiber = Coroutine.run(fiber)
      # ... later, when we have a result ...
      fiber = Coroutine.run(fiber, result)
      case fiber do
        %Coroutine.Completed{result: result} -> result
        %Coroutine.InternalSuspended{} -> :still_waiting
        %Coroutine.Errored{error: error} -> {:error, error}
      end
  """
  @spec run(t()) ::
          Completed.t()
          | InternalSuspended.t()
          | ExternalSuspended.t()
          | ForeignSuspended.t()
          | ForeignSuspensions.t()
          | Errored.t()
  def run(%Pending{computation: comp, env: env} = fiber) do
    {result, result_env} = Comp.call(comp, env, &Comp.identity_k/2)
    {sentinel_result, sentinel_env} = ISentinel.run(result, result_env)
    execute_and_handle(fiber, sentinel_env, fn -> {sentinel_result, sentinel_env} end)
  end

  def run(fiber) do
    raise ArgumentError,
          "Cannot run fiber without value: expected %Coroutine.Pending{}, got #{inspect(fiber.__struct__)}"
  end

  @spec run(t(), term()) ::
          Completed.t()
          | InternalSuspended.t()
          | ExternalSuspended.t()
          | ForeignSuspended.t()
          | ForeignSuspensions.t()
          | Errored.t()
  def run(%InternalSuspended{k: k, env: env} = fiber, value) do
    {result, result_env} = k.(value, env)
    {sentinel_result, sentinel_env} = ISentinel.run(result, result_env)
    execute_and_handle(fiber, sentinel_env, fn -> {sentinel_result, sentinel_env} end)
  end

  def run(%ExternalSuspended{k: k, env: env} = fiber, value) do
    {result, result_env} = k.(value, env)
    {sentinel_result, sentinel_env} = ISentinel.run(result, result_env)
    execute_and_handle(fiber, sentinel_env, fn -> {sentinel_result, sentinel_env} end)
  end

  def run(
        %ForeignSuspended{suspend: %Comp.ForeignSuspend{resume: resume}, env: env} = fiber,
        value
      ) do
    {result, result_env} = resume.(value, env)
    {sentinel_result, sentinel_env} = ISentinel.run(result, result_env)
    execute_and_handle(fiber, sentinel_env, fn -> {sentinel_result, sentinel_env} end)
  end

  def run(%ForeignSuspensions{resume: resume, id: id}, resolved) do
    {result, result_env} = resume.(resolved)

    case result do
      %ForeignSuspensions{} = fs ->
        ISentinel.run(fs, result_env)

      _ ->
        %Completed{id: id, result: result, env: result_env}
    end
  end

  def run(fiber, _value) do
    raise ArgumentError,
          "Cannot run fiber: expected %Coroutine.Pending{}, %Coroutine.InternalSuspended{}, %Coroutine.ExternalSuspended{}, %Coroutine.ForeignSuspended{}, or %Coroutine.ForeignSuspensions{}, got #{inspect(fiber.__struct__)}"
  end

  @doc """
  Step a fiber without applying `ISentinel.run`.

  Like `run/1,2` but produces raw typed states without `transform_suspend`
  or `leave_scope`. For use inside the FiberPool scheduler, which applies
  `ISentinel.run` at its own boundary.

  ## Examples

      fiber = Coroutine.new(my_comp, env)
      fiber = Coroutine.call(fiber)
      case fiber do
        %Coroutine.InternalSuspended{} -> :needs_scheduler
        %Coroutine.ExternalSuspended{k: k, env: env} -> handle_external(k, env)
      end
  """
  @spec call(t()) ::
          Completed.t()
          | InternalSuspended.t()
          | ExternalSuspended.t()
          | ForeignSuspended.t()
          | ForeignSuspensions.t()
          | Errored.t()
  def call(%Pending{computation: comp, env: env} = fiber) do
    do_call(fiber, comp, env)
  end

  def call(fiber) do
    raise ArgumentError,
          "Cannot call fiber without value: expected %Coroutine.Pending{}, got #{inspect(fiber.__struct__)}"
  end

  @spec call(t(), term()) ::
          Completed.t()
          | InternalSuspended.t()
          | ExternalSuspended.t()
          | ForeignSuspended.t()
          | ForeignSuspensions.t()
          | Errored.t()
  def call(%InternalSuspended{k: k, env: env} = fiber, value) do
    do_resume(fiber, k, value, env)
  end

  def call(%ExternalSuspended{k: k, env: env} = fiber, value) do
    do_resume(fiber, k, value, env)
  end

  def call(
        %ForeignSuspended{suspend: %Comp.ForeignSuspend{resume: resume}, env: env} = fiber,
        value
      ) do
    do_resume(fiber, resume, value, env)
  end

  def call(%ForeignSuspensions{resume: resume, id: id}, resolved) do
    {result, result_env} = resume.(resolved)

    case result do
      %ForeignSuspensions{} = fs -> fs
      %Completed{} = c -> c
      _ -> %Completed{id: id, result: result, env: result_env}
    end
  end

  def call(fiber, _value) do
    raise ArgumentError,
          "Cannot call fiber: expected %Coroutine.Pending{}, %Coroutine.InternalSuspended{}, %Coroutine.ExternalSuspended{}, %Coroutine.ForeignSuspended{}, or %Coroutine.ForeignSuspensions{}, got #{inspect(fiber.__struct__)}"
  end

  @doc """
  Cancel a fiber, invoking leave_scope cleanup for suspended fibers.

  For suspended fibers, creates a `%Cancelled{}` sentinel and runs it
  through the leave_scope chain, giving scoped effects an opportunity
  to clean up resources.

  For `%Pending{}` fibers, no scopes have been entered yet so no cleanup
  is needed.

  For already-terminal fibers (`%Completed{}`, `%Cancelled{}`, `%Errored{}`),
  cancel is a no-op — the fiber is returned unchanged.

  ## Parameters

  - `fiber` - The fiber to cancel
  - `reason` - The cancellation reason (default: `:cancelled`)

  ## Example

      fiber = Coroutine.cancel(fiber, :timeout)
      assert match?(%Coroutine.Cancelled{}, fiber)
  """
  @spec cancel(t(), term()) :: t()
  def cancel(fiber, reason \\ :cancelled)

  # Already terminal — no-op
  def cancel(%m{} = fiber, _reason) when m in [Completed, Cancelled, Errored] do
    fiber
  end

  # Suspended — run leave_scope cleanup
  def cancel(%InternalSuspended{id: id, env: env} = _fiber, reason) do
    cancelled = %Comp.Cancelled{reason: reason}
    {_result, final_env} = Env.run_leave_scope(env, cancelled)
    %Cancelled{id: id, reason: reason, env: final_env}
  end

  def cancel(%ExternalSuspended{id: id, env: env} = _fiber, reason) do
    cancelled = %Comp.Cancelled{reason: reason}
    {_result, final_env} = Env.run_leave_scope(env, cancelled)
    %Cancelled{id: id, reason: reason, env: final_env}
  end

  def cancel(%ForeignSuspended{id: id, env: env} = _fiber, reason) do
    cancelled = %Comp.Cancelled{reason: reason}
    {_result, final_env} = Env.run_leave_scope(env, cancelled)
    %Cancelled{id: id, reason: reason, env: final_env}
  end

  def cancel(%ForeignSuspensions{id: id, env: env} = _fiber, reason) do
    cancelled = %Comp.Cancelled{reason: reason}
    {_result, final_env} = Env.run_leave_scope(env, cancelled)
    %Cancelled{id: id, reason: reason, env: final_env}
  end

  # Pending — hard clear, no cleanup needed
  def cancel(%Pending{} = fiber, reason) do
    %Cancelled{id: fiber.id, reason: reason, env: nil}
  end

  @doc """
  Check if a fiber is in a terminal state (completed, cancelled, or errored).
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%m{}) when m in [Completed, Cancelled, Errored], do: true
  def terminal?(_), do: false

  #############################################################################
  ## Internal
  #############################################################################

  # Start a computation (raw — no ISentinel.run)
  defp do_call(fiber, comp, env) do
    execute_and_handle(fiber, env, fn -> Comp.call(comp, env, &Comp.identity_k/2) end)
  end

  # Resume via continuation (raw — no ISentinel.run)
  defp do_resume(fiber, k, value, env) do
    execute_and_handle(fiber, env, fn -> k.(value, env) end)
  end

  # Normalize Comp.Throw error payload into a Coroutine.Error struct
  defp normalize_throw_error(%{kind: :error, payload: exception, stacktrace: stacktrace}) do
    %Error{type: :exception, error: exception, stacktrace: stacktrace}
  end

  defp normalize_throw_error(%{kind: :throw, payload: value, stacktrace: stacktrace}) do
    %Error{type: :throw, error: value, stacktrace: stacktrace}
  end

  defp normalize_throw_error(%{kind: :exit, payload: reason, stacktrace: stacktrace}) do
    %Error{type: :exit, error: reason, stacktrace: stacktrace}
  end

  defp normalize_throw_error(plain_value) do
    %Error{type: :throw, error: plain_value}
  end

  # Execute an invocation and handle all result types.
  # Returns the fiber in its new state.
  defp execute_and_handle(fiber, env, invocation) do
    case invocation.() do
      {%Comp.ExternalSuspend{} = suspend, suspend_env} ->
        handle_external_suspend(fiber, suspend, suspend_env)

      {%InternalSuspend{} = internal_suspend, internal_env} ->
        handle_internal_suspend(fiber, internal_suspend, internal_env)

      {%Comp.ForeignSuspend{} = suspend, suspend_env} ->
        handle_foreign_suspend(fiber, suspend, suspend_env)

      {%Comp.Throw{} = throw, throw_env} ->
        error = normalize_throw_error(throw.error)
        %Errored{id: fiber.id, error: error, env: throw_env}

      {%Comp.Cancelled{} = cancelled, cancelled_env} ->
        %Errored{
          id: fiber.id,
          error: %Error{type: :cancelled, error: cancelled.reason},
          env: cancelled_env
        }

      {value, %Env{} = final_env} ->
        %Completed{id: fiber.id, result: value, env: final_env}
    end
  rescue
    e ->
      %Errored{
        id: fiber.id,
        error: %Error{type: :exception, error: e, stacktrace: __STACKTRACE__},
        env: env
      }
  catch
    :throw, reason ->
      %Errored{id: fiber.id, error: %Error{type: :throw, error: reason}, env: env}

    :exit, reason ->
      %Errored{id: fiber.id, error: %Error{type: :exit, error: reason}, env: env}
  end

  # Handle an external Suspend sentinel (closes over env)
  defp handle_external_suspend(
         fiber,
         %Comp.ExternalSuspend{value: value, data: data, resume: resume},
         env
       ) do
    k = fn resume_value, _env ->
      resume.(resume_value)
    end

    %ExternalSuspended{id: fiber.id, value: value, data: data, k: k, env: env}
  end

  # Handle a foreign suspend — wrap into ForeignSuspensions aggregate
  defp handle_foreign_suspend(
         fiber,
         %Comp.ForeignSuspend{} = suspend,
         env
       ) do
    %ForeignSuspended{
      id: fiber.id,
      suspend: suspend,
      env: env
    }
  end

  # Handle an internal suspend (receives env at resume time)
  defp handle_internal_suspend(fiber, %InternalSuspend{resume: resume} = internal_suspend, env) do
    k = fn value, resume_env ->
      resume.(value, resume_env)
    end

    %InternalSuspended{id: fiber.id, k: k, suspend: internal_suspend, env: env}
  end
end
