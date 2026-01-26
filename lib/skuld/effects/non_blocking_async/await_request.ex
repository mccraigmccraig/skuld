defmodule Skuld.Effects.NonBlockingAsync.AwaitRequest do
  @moduledoc """
  Request struct for awaiting async completions.

  An `AwaitRequest` specifies what the computation is waiting for (targets)
  and the wake condition (mode).

  ## Modes

  - `:all` - Wake when all targets complete, return results in order
  - `:any` - Wake when any target completes, return `{target, result}`

  ## Example

      # Wait for all tasks
      request = AwaitRequest.new([TaskTarget.new(task1), TaskTarget.new(task2)], :all)

      # Race a task against a timeout
      request = AwaitRequest.new([TaskTarget.new(task), TimerTarget.new(5000)], :any)

      # Wait for a fiber
      request = AwaitRequest.new([FiberTarget.new(fiber_id)], :all)
  """

  alias __MODULE__.TaskTarget
  alias __MODULE__.TimerTarget
  alias __MODULE__.ComputationTarget
  alias __MODULE__.FiberTarget

  defstruct [:id, :targets, :mode]

  @type mode :: :all | :any
  @type target :: TaskTarget.t() | TimerTarget.t() | ComputationTarget.t() | FiberTarget.t()
  @type target_key ::
          {:task, reference()}
          | {:timer, reference()}
          | {:computation, reference()}
          | {:fiber, reference()}

  @type t :: %__MODULE__{
          id: reference(),
          targets: [target()],
          mode: mode()
        }

  @doc """
  Create a new await request.

  ## Parameters

  - `targets` - List of target structs (TaskTarget, TimerTarget, ComputationTarget)
  - `mode` - `:all` to wait for all, `:any` to wait for first
  """
  @spec new([target()], mode()) :: t()
  def new(targets, mode) when is_list(targets) and mode in [:all, :any] do
    %__MODULE__{id: make_ref(), targets: targets, mode: mode}
  end

  @doc """
  Get the target keys for all targets in this request.
  """
  @spec target_keys(t()) :: [target_key()]
  def target_keys(%__MODULE__{targets: targets}) do
    Enum.map(targets, &__MODULE__.Target.key/1)
  end
end

defprotocol Skuld.Effects.NonBlockingAsync.AwaitRequest.Target do
  @moduledoc """
  Protocol for await targets.

  Enables the scheduler to extract a unique key for correlating
  completion messages back to waiting computations.
  """

  @doc """
  Return a unique key that identifies this target for message correlation.

  Keys are tuples like `{:task, ref}`, `{:timer, ref}`, `{:computation, ref}`.
  """
  @spec key(t) :: Skuld.Effects.NonBlockingAsync.AwaitRequest.target_key()
  def key(target)
end

defmodule Skuld.Effects.NonBlockingAsync.AwaitRequest.TaskTarget do
  @moduledoc """
  Target for awaiting an Elixir Task.

  The key is derived from the task's ref, which is used by the BEAM
  to send completion messages.
  """

  defstruct [:task]

  @type t :: %__MODULE__{task: Task.t()}

  @doc "Create a TaskTarget from a Task struct."
  @spec new(Task.t()) :: t()
  def new(%Task{} = task), do: %__MODULE__{task: task}

  defimpl Skuld.Effects.NonBlockingAsync.AwaitRequest.Target do
    def key(%{task: %Task{ref: ref}}), do: {:task, ref}
  end
end

defmodule Skuld.Effects.NonBlockingAsync.AwaitRequest.TimerTarget do
  @moduledoc """
  Target for awaiting a timer.

  Timers are created with a deadline (monotonic time). The scheduler
  is responsible for calling `start/1` to arm the timer via
  `Process.send_after/3`.

  ## Reusable Timers

  The same timer can be used across multiple `await_any` calls to
  implement an overall operation timeout:

      timer = TimerTarget.new(5000)  # 5 second overall timeout

      # First operation races against timer
      {winner1, r1} <- await_any([TaskTarget.new(h1), timer])

      # Second operation uses same timer (time continues counting)
      {winner2, r2} <- await_any([TaskTarget.new(h2), timer])
  """

  defstruct [:ref, :deadline, :timer_ref]

  @type t :: %__MODULE__{
          ref: reference(),
          deadline: integer(),
          timer_ref: reference() | nil
        }

  @doc """
  Create a TimerTarget that will fire after `timeout_ms` milliseconds.

  The timer is not started until `start/1` is called.
  """
  @spec new(non_neg_integer()) :: t()
  def new(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    %__MODULE__{ref: make_ref(), deadline: deadline, timer_ref: nil}
  end

  @doc """
  Create a TimerTarget with an absolute deadline (monotonic time in milliseconds).
  """
  @spec new_absolute(integer()) :: t()
  def new_absolute(deadline) when is_integer(deadline) do
    %__MODULE__{ref: make_ref(), deadline: deadline, timer_ref: nil}
  end

  @doc """
  Start the timer. Returns updated target with timer_ref set.

  If the deadline has already passed, returns `{:already_expired, target}`.
  Otherwise returns `{:ok, target}` with the timer armed.
  """
  @spec start(t()) :: {:ok, t()} | {:already_expired, t()}
  def start(%__MODULE__{ref: ref, deadline: deadline, timer_ref: nil} = target) do
    now = System.monotonic_time(:millisecond)
    remaining = deadline - now

    if remaining <= 0 do
      {:already_expired, target}
    else
      timer_ref = Process.send_after(self(), {:timeout, ref, :fired}, remaining)
      {:ok, %{target | timer_ref: timer_ref}}
    end
  end

  def start(%__MODULE__{timer_ref: timer_ref} = target) when timer_ref != nil do
    # Already started
    {:ok, target}
  end

  @doc """
  Cancel the timer if it's running.
  """
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{timer_ref: nil} = target), do: target

  def cancel(%__MODULE__{timer_ref: timer_ref} = target) do
    Process.cancel_timer(timer_ref)
    %{target | timer_ref: nil}
  end

  @doc """
  Check if the timer has expired (deadline has passed).
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{deadline: deadline}) do
    System.monotonic_time(:millisecond) >= deadline
  end

  defimpl Skuld.Effects.NonBlockingAsync.AwaitRequest.Target do
    def key(%{ref: ref}), do: {:timer, ref}
  end
end

defmodule Skuld.Effects.NonBlockingAsync.AwaitRequest.ComputationTarget do
  @moduledoc """
  Target for awaiting an AsyncComputation.

  This enables composition of AsyncComputations - one computation can
  await the result of another without blocking.
  """

  alias Skuld.AsyncComputation

  defstruct [:runner]

  @type t :: %__MODULE__{runner: AsyncComputation.t()}

  @doc "Create a ComputationTarget from an AsyncComputation runner."
  @spec new(AsyncComputation.t()) :: t()
  def new(%AsyncComputation{} = runner), do: %__MODULE__{runner: runner}

  defimpl Skuld.Effects.NonBlockingAsync.AwaitRequest.Target do
    # Use tag (not ref) because AsyncComputation messages are {AsyncComputation, tag, result}
    def key(%{runner: %{tag: tag}}), do: {:computation, tag}
  end
end

defmodule Skuld.Effects.NonBlockingAsync.AwaitRequest.FiberTarget do
  @moduledoc """
  Target for awaiting a cooperative fiber.

  Fibers are computations that run cooperatively in the scheduler process.
  Unlike Tasks which run in separate Erlang processes, fibers share
  the scheduler's process and yield explicitly.

  The scheduler checks `fiber_results` to determine if a fiber has completed.
  """

  defstruct [:fiber_id]

  @type t :: %__MODULE__{fiber_id: reference()}

  @doc "Create a FiberTarget from a fiber ID reference."
  @spec new(reference()) :: t()
  def new(fiber_id) when is_reference(fiber_id), do: %__MODULE__{fiber_id: fiber_id}

  defimpl Skuld.Effects.NonBlockingAsync.AwaitRequest.Target do
    def key(%{fiber_id: fiber_id}), do: {:fiber, fiber_id}
  end
end
