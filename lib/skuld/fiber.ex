defmodule Skuld.Fiber do
  @moduledoc """
  Cooperative fiber primitive for the FiberPool scheduler.

  A Fiber wraps a computation that can be run incrementally, suspended when it
  yields, and resumed with a value. This is the fundamental building block for
  cooperative concurrency in Skuld.

  ## Lifecycle

  1. Create with `new/2` - fiber is `:pending`
  2. Run with `run_until_suspend/1` - fiber becomes `:running`, then reaches a
     terminal or suspended state. All state is captured in the struct:
     - `:completed` - `result` and `env` are set
     - `:suspended` - `suspended_k`, `env`, and optionally `internal_suspend` are set
     - `:error` - `error` and `env` are set
  3. Resume with `resume/2` - suspended fiber runs again until completion/suspension
  4. Cancel with `cancel/1` - marks fiber as `:cancelled`

  ## Usage

  Fibers are typically managed by a FiberPool, not used directly. The FiberPool
  scheduler handles running fibers, tracking suspensions, and resuming when
  results are available.

  ## State Convention

  All fiber state is consolidated in the struct. Callers switch on
  `fiber.status` rather than pattern-matching different tuple shapes.
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
          internal_suspend: InternalSuspend.t() | nil,
          env: Types.env() | nil,
          result: term(),
          error: term()
        }

  defstruct [:id, :status, :computation, :suspended_k, :internal_suspend, :env, :result, :error]

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

  Takes a `:pending` fiber and runs its computation. Returns the fiber with
  all state consolidated in the struct. Callers switch on `fiber.status`:

  - `:completed` - `fiber.result` and `fiber.env` are set
  - `:suspended` - `fiber.suspended_k` and `fiber.env` are set;
    `fiber.internal_suspend` is set for internal suspensions (batch/channel/await)
  - `:error` - `fiber.error` and `fiber.env` are set

  The returned fiber (on suspension) can be resumed with `resume/2`.

  ## Example

      fiber = Fiber.new(my_comp, env)
      fiber = Fiber.run_until_suspend(fiber)
      case fiber.status do
        :completed -> IO.puts("Done: \#{inspect(fiber.result)}")
        :suspended -> IO.puts("Suspended, can resume later")
        :error -> IO.puts("Error: \#{inspect(fiber.error)}")
      end
  """
  @spec run_until_suspend(t()) :: t()
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
  with the provided value. Returns the fiber with updated state — same contract
  as `run_until_suspend/1`.

  ## Parameters

  - `fiber` - A fiber in `:suspended` status
  - `value` - The value to resume with (typically a result from an effect)

  ## Example

      fiber = Fiber.run_until_suspend(fiber)
      # ... later, when we have a result ...
      fiber = Fiber.resume(fiber, result)
      case fiber.status do
        :completed -> fiber.result
        :suspended -> # suspended again
        :error -> # errored
      end
  """
  @spec resume(t(), term()) :: t()
  def resume(%__MODULE__{status: :suspended, suspended_k: k, env: env} = fiber, value)
      when is_function(k, 2) do
    fiber = %{fiber | status: :running, suspended_k: nil, internal_suspend: nil, env: nil}
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
    %{
      fiber
      | status: :cancelled,
        computation: nil,
        suspended_k: nil,
        internal_suspend: nil,
        env: nil,
        result: nil,
        error: nil
    }
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

  # Execute an invocation and handle all result types.
  # Returns the fiber with all state consolidated in the struct.
  defp execute_and_handle(fiber, env, invocation) do
    case invocation.() do
      {%Comp.ExternalSuspend{} = suspend, suspend_env} ->
        handle_external_suspend(fiber, suspend, suspend_env)

      {%InternalSuspend{} = internal_suspend, internal_env} ->
        handle_internal_suspend(fiber, internal_suspend, internal_env)

      {%Comp.Throw{} = throw, throw_env} ->
        %{fiber | status: :error, error: {:throw, throw.error}, env: throw_env}

      {%Comp.Cancelled{} = cancelled, cancelled_env} ->
        %{fiber | status: :error, error: {:cancelled, cancelled.reason}, env: cancelled_env}

      {value, %Env{} = final_env} ->
        %{fiber | status: :completed, result: value, env: final_env}
    end
  rescue
    e ->
      %{fiber | status: :error, error: {:exception, e, __STACKTRACE__}, env: env}
  catch
    :throw, reason ->
      %{fiber | status: :error, error: {:throw, reason}, env: env}

    :exit, reason ->
      %{fiber | status: :error, error: {:exit, reason}, env: env}
  end

  # Handle an external Suspend sentinel (closes over env)
  # Used for callbacks to non-Skuld code
  defp handle_external_suspend(fiber, %Comp.ExternalSuspend{resume: resume}, env) do
    # The Suspend.resume is (val -> {result, env}), closes over env at suspension
    # We wrap it to match our (val, env) -> {result, env} signature
    suspended_k = fn value, _env ->
      # Ignore the passed env - external suspend has env already bound
      resume.(value)
    end

    %{
      fiber
      | status: :suspended,
        suspended_k: suspended_k,
        internal_suspend: nil,
        env: env
    }
  end

  # Handle an internal suspend (receives env at resume time)
  # Used by FiberPool scheduler for batch/channel/await operations
  defp handle_internal_suspend(fiber, %InternalSuspend{resume: resume} = internal_suspend, env) do
    # InternalSuspend.resume is (val, env -> {result, env})
    # Pass the resume_env at resume time to allow scheduler to thread updated state
    suspended_k = fn value, resume_env ->
      resume.(value, resume_env)
    end

    %{
      fiber
      | status: :suspended,
        suspended_k: suspended_k,
        internal_suspend: internal_suspend,
        env: env
    }
  end
end
