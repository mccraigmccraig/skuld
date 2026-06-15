defmodule Skuld.PageMachine.Spindle do
  @moduledoc """
  Named coroutine fibers managed by the PageMachine main loop.

  A spindle wraps a coroutine fiber with an atom key that identifies it
  in the main loop. The main loop steps each spindle, tags its yields
  with the key, and routes incoming events to the correct spindle.

  ## Lifecycle

  1. A computation calls `Spindle.fork(:cart, comp)` — this returns a ref
  2. The PageMachine main loop detects the fork, creates a Spindle struct,
     and adds it to its registry
  3. When the spindle fiber yields (`Yield.yield`), the main loop wraps
     the value as `{:spindle, :cart, value}` and forwards to the LiveView
  4. When the LiveView sends an event for that spindle, the main loop
     resumes the fiber
  5. When the spindle completes, the main loop removes it from the registry
  """

  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Coroutine

  defstruct [:key, :fiber, :ref]

  @typedoc "A named coroutine fiber managed by the PageMachine main loop."
  @type t :: %__MODULE__{
          key: atom(),
          fiber: Coroutine.t(),
          ref: reference()
        }

  @doc """
  Create a new spindle from a computation. The spindle starts as pending
  — it must be stepped via `step/2` before it runs.
  """
  @spec new(atom(), Types.computation(), Env.t()) :: t()
  def new(key, computation, env) when is_atom(key) do
    fiber = Coroutine.new(computation, env)
    %__MODULE__{key: key, fiber: fiber, ref: make_ref()}
  end

  @doc """
  Step a spindle forward. Runs from current state — starts a pending spindle,
  or resumes a suspended spindle with the given value.

  Returns `{:yield, spindle, value}` if the spindle yielded,
  `{:complete, spindle, result}` if it completed,
  `{:error, spindle, error}` if it errored.
  """
  @spec step(t()) ::
          {:yield, t(), term()}
          | {:complete, t(), term()}
          | {:error, t(), term()}
  def step(%__MODULE__{fiber: fiber} = spindle) do
    resolved = Coroutine.run(fiber)

    case resolved do
      %Coroutine.ExternalSuspended{value: value} ->
        {:yield, %{spindle | fiber: resolved}, value}

      %Coroutine.Completed{result: result} ->
        {:complete, %{spindle | fiber: resolved}, result}

      %Coroutine.Errored{error: error} ->
        {:error, %{spindle | fiber: resolved}, error}

      other ->
        raise "unexpected spindle fiber state: #{inspect(other)}"
    end
  end

  @doc """
  Step a spindle forward with a resume value. Use for suspended spindles
  that need an event to continue.
  """
  @spec step(t(), term()) ::
          {:yield, t(), term()}
          | {:complete, t(), term()}
          | {:error, t(), term()}
  def step(%__MODULE__{fiber: fiber} = spindle, value) do
    resolved = Coroutine.run(fiber, value)

    case resolved do
      %Coroutine.ExternalSuspended{value: value} ->
        {:yield, %{spindle | fiber: resolved}, value}

      %Coroutine.Completed{result: result} ->
        {:complete, %{spindle | fiber: resolved}, result}

      %Coroutine.Errored{error: error} ->
        {:error, %{spindle | fiber: resolved}, error}

      other ->
        raise "unexpected spindle fiber state: #{inspect(other)}"
    end
  end

  @doc """
  Tag a spindle yield for forwarding to the LiveView.
  Returns `{:spindle, key, value}`.
  """
  @spec tag_yield(t(), term()) :: {:spindle, atom(), term()}
  def tag_yield(%__MODULE__{key: key}, value), do: {:spindle, key, value}

  @doc """
  Cancel a spindle, running leave_scope cleanup.
  """
  @spec cancel(t(), term()) :: t()
  def cancel(%__MODULE__{fiber: fiber} = spindle, reason \\ :cancelled) do
    cancelled = Coroutine.cancel(fiber, reason)
    %{spindle | fiber: cancelled}
  end
end
