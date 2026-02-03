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
  alias Skuld.Comp.Types
  alias Skuld.Fiber.FiberPool.BatchSuspend
  alias Skuld.Fiber.FiberPool.Suspend, as: FPSuspend
  alias Skuld.Effects.Channel.Suspend, as: ChannelSuspend

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
  - `{:suspended, fiber}` - Fiber suspended, updated fiber has `:suspended_k` and `:env`
  - `{:batch_suspended, fiber, batch_suspend}` - Fiber suspended for batch operation
  - `{:error, reason, env}` - Fiber errored

  The returned fiber (on suspension) can be resumed with `resume/2`.

  ## Example

      fiber = Fiber.new(my_comp, env)
      case Fiber.run_until_suspend(fiber) do
        {:completed, result, _env} -> IO.puts("Done: \#{inspect(result)}")
        {:suspended, fiber} -> IO.puts("Suspended, can resume later")
        {:batch_suspended, fiber, batch} -> IO.puts("Batch suspended: \#{inspect(batch)}")
        {:error, reason, _env} -> IO.puts("Error: \#{inspect(reason)}")
      end
  """
  @spec run_until_suspend(t()) ::
          {:completed, term(), Types.env()}
          | {:suspended, t()}
          | {:batch_suspended, t(), BatchSuspend.t()}
          | {:channel_suspended, t(), ChannelSuspend.t()}
          | {:fp_suspended, t(), FPSuspend.t()}
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
        {:suspended, fiber} -> # suspended again
        {:batch_suspended, fiber, batch} -> # batch suspended
        {:error, reason, _env} -> # errored
      end
  """
  @spec resume(t(), term()) ::
          {:completed, term(), Types.env()}
          | {:suspended, t()}
          | {:batch_suspended, t(), BatchSuspend.t()}
          | {:channel_suspended, t(), ChannelSuspend.t()}
          | {:fp_suspended, t(), FPSuspend.t()}
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
        handle_suspend(fiber, suspend, suspend_env)

      {%BatchSuspend{} = batch_suspend, batch_env} ->
        handle_batch_suspend(fiber, batch_suspend, batch_env)

      {%ChannelSuspend{} = channel_suspend, channel_env} ->
        handle_channel_suspend(fiber, channel_suspend, channel_env)

      {%FPSuspend{} = fp_suspend, fp_env} ->
        handle_fp_suspend(fiber, fp_suspend, fp_env)

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

  # Handle a Suspend sentinel - store continuation and env in fiber
  defp handle_suspend(fiber, %Comp.Suspend{resume: resume}, env) do
    # The Suspend.resume is (val -> {result, env}), but we need (val, env) -> {result, env}
    # for our suspended_k. We capture the env at suspension point.
    suspended_k = fn value, _env ->
      # Note: we ignore the passed env and use the captured one from suspend
      # This is because Suspend.resume already has the env bound
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

  # Handle a BatchSuspend sentinel - return the batch suspend for scheduler to handle
  defp handle_batch_suspend(fiber, %BatchSuspend{resume: resume} = batch_suspend, env) do
    # Store the resume function in the fiber so it can be resumed after batch execution
    suspended_k = fn value, resume_env ->
      # BatchSuspend.resume is (val, env -> {result, env})
      # Pass the resume_env (which has pending fibers cleared) to avoid re-collecting
      resume.(value, resume_env)
    end

    suspended_fiber = %{
      fiber
      | status: :suspended,
        suspended_k: suspended_k,
        env: env
    }

    # Return the batch_suspend so the scheduler can extract the op for batching
    {:batch_suspended, suspended_fiber, batch_suspend}
  end

  # Handle a ChannelSuspend sentinel - return the channel suspend for scheduler to handle
  defp handle_channel_suspend(fiber, %ChannelSuspend{resume: resume} = channel_suspend, env) do
    # Store the resume function in the fiber so it can be resumed when channel is ready
    suspended_k = fn value, resume_env ->
      # ChannelSuspend.resume is (val, env -> {result, env})
      # Pass the resume_env (which has pending fibers cleared) to avoid re-collecting
      resume.(value, resume_env)
    end

    suspended_fiber = %{
      fiber
      | status: :suspended,
        suspended_k: suspended_k,
        env: env
    }

    # Return the channel_suspend so the scheduler can track it
    {:channel_suspended, suspended_fiber, channel_suspend}
  end

  # Handle an FPSuspend (FiberPool await) - return the suspend for scheduler to handle
  defp handle_fp_suspend(fiber, %FPSuspend{resume: resume} = fp_suspend, env) do
    # Store the resume function in the fiber so it can be resumed when await is satisfied
    suspended_k = fn value, resume_env ->
      # FPSuspend.resume is (val, env -> {result, env})
      # Pass the resume_env (which has pending fibers cleared) to avoid re-collecting
      resume.(value, resume_env)
    end

    suspended_fiber = %{
      fiber
      | status: :suspended,
        suspended_k: suspended_k,
        env: env
    }

    # Return the fp_suspend so the scheduler can handle the await
    {:fp_suspended, suspended_fiber, fp_suspend}
  end
end
