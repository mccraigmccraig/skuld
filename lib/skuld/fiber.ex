defmodule Skuld.Fiber do
  @moduledoc """
  Cooperative fiber primitive for the FiberPool scheduler.

  A Fiber wraps a computation that can be run incrementally, suspended when it
  yields, and resumed with a value. This is the fundamental building block for
  cooperative concurrency in Skuld.

  ## Sum Type

  A fiber is always exactly one of these states — no `status` atom, no nil fields:

  - `%Fiber.Pending{id, computation, env}` — ready to start
  - `%Fiber.InternalSuspended{id, k, suspend, env}` — suspended, needs scheduler
  - `%Fiber.ExternalSuspended{id, k, env}` — suspended, external callback
  - `%Fiber.Completed{id, result, env}` — finished successfully
  - `%Fiber.Errored{id, error, env}` — finished with error
  - `%Fiber.Cancelled{id, reason, env}` — cancelled before completion

  ## Lifecycle

  1. Create with `new/2` — returns `%Pending{}`
  2. Run with `run_until_suspend/1` — returns `%Completed{}`, `%InternalSuspended{}`,
     `%ExternalSuspended{}`, or `%Errored{}`
  3. Resume with `resume/2` — suspended fiber runs again until
     completion/suspension/error
  4. Cancel with `cancel/2` — invokes leave_scope cleanup, returns `%Cancelled{}`

  ## Usage

  Fibers are typically managed by a FiberPool, not used directly. The FiberPool
  scheduler handles running fibers, tracking suspensions, and resuming when
  results are available.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Comp.Types
  alias Skuld.Fiber.Cancelled
  alias Skuld.Fiber.Completed
  alias Skuld.Fiber.Error
  alias Skuld.Fiber.Errored
  alias Skuld.Fiber.ExternalSuspended
  alias Skuld.Fiber.InternalSuspended
  alias Skuld.Fiber.Pending

  @typedoc """
  A fiber in any state.

  Callers pattern-match on the struct name to determine state:
  `%Pending{}`, `%InternalSuspended{}`, `%ExternalSuspended{}`,
  `%Completed{}`, `%Errored{}`, `%Cancelled{}`.
  """
  @type t ::
          Pending.t()
          | InternalSuspended.t()
          | ExternalSuspended.t()
          | Completed.t()
          | Errored.t()
          | Cancelled.t()

  @doc """
  Create a new fiber from a computation.

  The fiber starts as `%Pending{}` with the computation and env stored,
  ready to be run with `run_until_suspend/1`.

  ## Parameters

  - `comp` - The computation to run as a fiber
  - `env` - The environment to run in (typically inherited from parent)

  ## Example

      fiber = Fiber.new(my_comp, env)
      assert match?(%Fiber.Pending{}, fiber)
  """
  @spec new(Types.computation(), Types.env()) :: Pending.t()
  def new(comp, env) do
    %Pending{
      id: make_ref(),
      computation: comp,
      env: env
    }
  end

  @doc """
  Run a pending fiber until it completes, suspends, or errors.

  Takes a `%Pending{}` fiber and runs its computation. Returns one of:

  - `%Completed{result, env}` — finished successfully
  - `%InternalSuspended{k, suspend, env}` — suspended for scheduler
  - `%ExternalSuspended{k, env}` — suspended for external callback
  - `%Errored{error, env}` — finished with error

  A suspended fiber can be resumed with `resume/2`.

  ## Example

      fiber = Fiber.new(my_comp, env)
      fiber = Fiber.run_until_suspend(fiber)
      case fiber do
        %Fiber.Completed{result: result} -> IO.puts("Done: \#{inspect(result)}")
        %Fiber.InternalSuspended{} -> IO.puts("Suspended, can resume later")
        %Fiber.Errored{error: error} -> IO.puts("Error: \#{inspect(error)}")
      end
  """
  @spec run_until_suspend(Pending.t()) ::
          Completed.t() | InternalSuspended.t() | ExternalSuspended.t() | Errored.t()
  def run_until_suspend(%Pending{computation: comp, env: env} = fiber) do
    do_run(fiber, comp, env)
  end

  def run_until_suspend(fiber) do
    raise ArgumentError,
          "Cannot run fiber: expected %Fiber.Pending{}, got #{inspect(fiber.__struct__)}"
  end

  @doc """
  Resume a suspended fiber with a value.

  Takes a suspended fiber and resumes it by calling the suspended continuation
  with the provided value. Returns the fiber with updated state — same contract
  as `run_until_suspend/1`.

  ## Parameters

  - `fiber` - A fiber in suspended state (`%InternalSuspended{}` or `%ExternalSuspended{}`)
  - `value` - The value to resume with (typically a result from an effect)

  ## Example

      fiber = Fiber.run_until_suspend(fiber)
      # ... later, when we have a result ...
      fiber = Fiber.resume(fiber, result)
      case fiber do
        %Fiber.Completed{result: result} -> result
        _ -> # suspended again or errored
      end
  """
  @spec resume(InternalSuspended.t() | ExternalSuspended.t(), term()) ::
          Completed.t() | InternalSuspended.t() | ExternalSuspended.t() | Errored.t()
  def resume(%InternalSuspended{k: k, env: env} = fiber, value) do
    do_resume(fiber, k, value, env)
  end

  def resume(%ExternalSuspended{k: k, env: env} = fiber, value) do
    do_resume(fiber, k, value, env)
  end

  def resume(fiber, _value) do
    raise ArgumentError,
          "Cannot resume fiber: expected %Fiber.InternalSuspended{} or %Fiber.ExternalSuspended{}, got #{inspect(fiber.__struct__)}"
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

      fiber = Fiber.cancel(fiber, :timeout)
      assert match?(%Fiber.Cancelled{}, fiber)
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

  # Run a computation, handling the result
  defp do_run(fiber, comp, env) do
    execute_and_handle(fiber, env, fn -> Comp.call(comp, env, &Comp.identity_k/2) end)
  end

  # Resume via continuation
  defp do_resume(fiber, k, value, env) do
    execute_and_handle(fiber, env, fn -> k.(value, env) end)
  end

  # Normalize Comp.Throw error payload into a Fiber.Error struct
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

      {%Comp.Throw{} = throw, throw_env} ->
        error = normalize_throw_error(throw.error)
        %Errored{id: fiber.id, error: error, env: throw_env}

      {%Comp.Cancelled{} = cancelled, cancelled_env} ->
        %Errored{id: fiber.id, error: %Error{type: :cancelled, error: cancelled.reason}, env: cancelled_env}

      {value, %Env{} = final_env} ->
        %Completed{id: fiber.id, result: value, env: final_env}
    end
  rescue
    e ->
      %Errored{id: fiber.id, error: %Error{type: :exception, error: e, stacktrace: __STACKTRACE__}, env: env}
  catch
    :throw, reason ->
      %Errored{id: fiber.id, error: %Error{type: :throw, error: reason}, env: env}

    :exit, reason ->
      %Errored{id: fiber.id, error: %Error{type: :exit, error: reason}, env: env}
  end

  # Handle an external Suspend sentinel (closes over env)
  defp handle_external_suspend(fiber, %Comp.ExternalSuspend{resume: resume}, env) do
    k = fn value, _env ->
      resume.(value)
    end

    %ExternalSuspended{id: fiber.id, k: k, env: env}
  end

  # Handle an internal suspend (receives env at resume time)
  defp handle_internal_suspend(fiber, %InternalSuspend{resume: resume} = internal_suspend, env) do
    k = fn value, resume_env ->
      resume.(value, resume_env)
    end

    %InternalSuspended{id: fiber.id, k: k, suspend: internal_suspend, env: env}
  end
end
