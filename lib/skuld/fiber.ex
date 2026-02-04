defmodule Skuld.Fiber do
  @moduledoc """
  Cooperative fiber primitive for the FiberPool scheduler.

  A Fiber wraps a computation that can be run incrementally, suspended when it
  yields, and resumed with a value. This is the fundamental building block for
  cooperative concurrency in Skuld.

  ## Lifecycle

  1. Create with `new/2` - fiber is `:pending`
  2. Run with `run_until_suspend/1` - fiber becomes `:running`, then either:
     - Completes: returns `{:completed, result, env}`
     - Suspends: returns `{:suspended, fiber}` with fiber in `:suspended` state
     - Errors: returns `{:error, reason, env}`
  3. Resume with `resume/2` - suspended fiber runs again until completion/suspension
  4. Cancel with `cancel/1` - marks fiber as `:cancelled`

  ## Usage

  Fibers are typically managed by a FiberPool, not used directly. The FiberPool
  scheduler handles running fibers, tracking suspensions, and resuming when
  results are available.

  ## Internal Details

  When a fiber suspends, it stores:
  - `suspended_k` - the CPS continuation `(val, env) -> {result, env}`
  - `env` - the environment at suspension point

  Resume calls `suspended_k.(value, env)` to continue execution.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Comp.Types

  @type status :: :pending | :running | :suspended | :completed | :cancelled | :error

  @type t :: %__MODULE__{
          id: reference(),
          status: status(),
          computation: Types.computation() | nil,
          suspended_k: Types.k() | nil,
          env: Types.env() | nil
        }

  defstruct [:id, :status, :computation, :suspended_k, :env]

  @doc """
  Create a new fiber from a computation.

  The fiber starts in `:pending` status with the computation stored,
  ready to be run with `run_until_suspend/1`.

  ## Parameters

  - `comp` - The computation to run as a fiber
  - `env` - The environment to run in (typically inherited from parent)

  ## Example

      fiber = Fiber.new(my_comp, env)
      assert fiber.status == :pending
  """
  @spec new(Types.computation(), Types.env()) :: t()
  def new(comp, env) do
    %__MODULE__{
      id: make_ref(),
      status: :pending,
      computation: comp,
      suspended_k: nil,
      env: env
    }
  end

  @doc """
  Run a fiber until it completes, suspends, or errors.

  Takes a `:pending` fiber and runs its computation. Returns one of:

  - `{:completed, result, env}` - Fiber completed with result
  - `{:suspended, fiber}` - External suspension, updated fiber has `:suspended_k` and `:env`
  - `{:internal_suspended, fiber, internal_suspend}` - Internal suspension (batch/channel/await)
  - `{:error, reason, env}` - Fiber errored

  The returned fiber (on suspension) can be resumed with `resume/2`.

  ## Example

      fiber = Fiber.new(my_comp, env)
      case Fiber.run_until_suspend(fiber) do
        {:completed, result, _env} -> IO.puts("Done: \#{inspect(result)}")
        {:suspended, fiber} -> IO.puts("External suspended, can resume later")
        {:internal_suspended, fiber, suspend} -> IO.puts("Internal suspended: \#{inspect(suspend)}")
        {:error, reason, _env} -> IO.puts("Error: \#{inspect(reason)}")
      end
  """
  @spec run_until_suspend(t()) ::
          {:completed, term(), Types.env()}
          | {:suspended, t()}
          | {:internal_suspended, t(), InternalSuspend.t()}
          | {:error, term(), Types.env() | nil}
  def run_until_suspend(%__MODULE__{status: :pending, computation: comp, env: env} = fiber) do
    fiber = %{fiber | status: :running, computation: nil}
    do_run(fiber, comp, env)
  end

  def run_until_suspend(%__MODULE__{status: status}) do
    raise ArgumentError, "Cannot run fiber in #{status} status, expected :pending"
  end

  @doc """
  Resume a suspended fiber with a value.

  Takes a `:suspended` fiber and resumes it by calling the suspended continuation
  with the provided value. Returns the same result types as `run_until_suspend/1`.

  ## Parameters

  - `fiber` - A fiber in `:suspended` status
  - `value` - The value to resume with (typically a result from an effect)

  ## Example

      {:suspended, fiber} = Fiber.run_until_suspend(fiber)
      # ... later, when we have a result ...
      case Fiber.resume(fiber, result) do
        {:completed, final, _env} -> final
        {:suspended, fiber} -> # external suspended again
        {:internal_suspended, fiber, suspend} -> # internal suspended
        {:error, reason, _env} -> # errored
      end
  """
  @spec resume(t(), term()) ::
          {:completed, term(), Types.env()}
          | {:suspended, t()}
          | {:internal_suspended, t(), InternalSuspend.t()}
          | {:error, term(), Types.env() | nil}
  def resume(%__MODULE__{status: :suspended, suspended_k: k, env: env} = fiber, value)
      when is_function(k, 2) do
    fiber = %{fiber | status: :running, suspended_k: nil, env: nil}
    do_resume(fiber, k, value, env)
  end

  def resume(%__MODULE__{status: status}, _value) do
    raise ArgumentError, "Cannot resume fiber in #{status} status, expected :suspended"
  end

  @doc """
  Cancel a fiber.

  Marks the fiber as `:cancelled`. A cancelled fiber cannot be run or resumed.
  The FiberPool scheduler uses this to clean up fibers when their scope exits.

  ## Example

      fiber = Fiber.cancel(fiber)
      assert fiber.status == :cancelled
  """
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = fiber) do
    %{fiber | status: :cancelled, computation: nil, suspended_k: nil, env: nil}
  end

  @doc """
  Check if a fiber is in a terminal state (completed, cancelled, or error).
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}) do
    status in [:completed, :cancelled, :error]
  end

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

  # Execute an invocation and handle all result types
  defp execute_and_handle(fiber, env, invocation) do
    case invocation.() do
      {%Comp.Suspend{} = suspend, suspend_env} ->
        handle_external_suspend(fiber, suspend, suspend_env)

      {%InternalSuspend{} = internal_suspend, internal_env} ->
        handle_internal_suspend(fiber, internal_suspend, internal_env)

      {%Comp.Throw{} = throw, throw_env} ->
        {:error, {:throw, throw.error}, throw_env}

      {%Comp.Cancelled{} = cancelled, cancelled_env} ->
        {:error, {:cancelled, cancelled.reason}, cancelled_env}

      {value, %Env{} = final_env} ->
        {:completed, value, final_env}
    end
  rescue
    e ->
      {:error, {:exception, e, __STACKTRACE__}, env}
  catch
    :throw, reason ->
      {:error, {:throw, reason}, env}

    :exit, reason ->
      {:error, {:exit, reason}, env}
  end

  # Handle an external Suspend sentinel (closes over env)
  # Used for callbacks to non-Skuld code
  defp handle_external_suspend(fiber, %Comp.Suspend{resume: resume}, env) do
    # The Suspend.resume is (val -> {result, env}), closes over env at suspension
    # We wrap it to match our (val, env) -> {result, env} signature
    suspended_k = fn value, _env ->
      # Ignore the passed env - external suspend has env already bound
      resume.(value)
    end

    suspended_fiber = %{
      fiber
      | status: :suspended,
        suspended_k: suspended_k,
        env: env
    }

    {:suspended, suspended_fiber}
  end

  # Handle an internal suspend (receives env at resume time)
  # Used by FiberPool scheduler for batch/channel/await operations
  defp handle_internal_suspend(fiber, %InternalSuspend{resume: resume} = internal_suspend, env) do
    # InternalSuspend.resume is (val, env -> {result, env})
    # Pass the resume_env at resume time to allow scheduler to thread updated state
    suspended_k = fn value, resume_env ->
      resume.(value, resume_env)
    end

    suspended_fiber = %{
      fiber
      | status: :suspended,
        suspended_k: suspended_k,
        env: env
    }

    {:internal_suspended, suspended_fiber, internal_suspend}
  end
end
