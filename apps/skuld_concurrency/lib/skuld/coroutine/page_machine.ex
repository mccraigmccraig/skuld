defmodule Skuld.Coroutine.PageMachine do
  @moduledoc """
  Synchronous page-machine for effectful state machines.

  Wraps `Skuld.Coroutine`, returning tagged tuples instead of raw sum types.
  Use this when you want in-process testing without the overhead of a
  separate BEAM process. For cross-process use (e.g. LiveView), see
  `Skuld.AsyncCoroutine.AsyncPageMachine`.

  ## Example

      alias Skuld.Coroutine.PageMachine

      # Start — returns raw Coroutine sum type
      fiber = PageMachine.run(MyApp.CheckoutFlow.flow(cart))
      {:yield, :shipping} = PageMachine.dispatch(fiber)

      # Resume
      fiber = PageMachine.run(fiber, {:ok, %{address: "123 Main"}})
      {:yield, :payment} = PageMachine.dispatch(fiber)

      # Complete
      fiber = PageMachine.run(fiber, {:ok, %{card: "4242"}})
      {:complete, {:ok, order}} = PageMachine.dispatch(fiber)

  ## Return values (from `dispatch/1`)

  - `{:yield, value}` — computation yielded, waiting for input
  - `{:complete, result}` — computation finished successfully
  - `{:error, error}` — computation threw or errored
  - `{:cancel, reason}` — computation was cancelled
  """

  alias Skuld.Comp.Env
  alias Skuld.Coroutine

  @doc """
  Start a computation. Returns the raw Coroutine sum type.

  Use `dispatch/1` to convert to a tagged tuple when you're ready to
  pattern-match on the outcome.
  """
  def run(computation) when is_function(computation, 2) do
    computation |> Coroutine.new(Env.new()) |> Coroutine.run()
  end

  @doc """
  Resume a yielded computation with a value. Returns the raw Coroutine
  sum type.
  """
  def run(%Coroutine.ExternalSuspended{} = fiber, value) do
    fiber |> Coroutine.run(value)
  end

  @doc """
  Cancel a running computation. Returns the raw Coroutine sum type.
  """
  def cancel(%Coroutine.ExternalSuspended{} = fiber, reason \\ :cancelled) do
    fiber |> Coroutine.cancel(reason)
  end

  @doc """
  Convert a raw Coroutine sum type to a tagged tuple for pattern matching.

  Returns `{:yield, value}`, `{:complete, result}`, `{:error, error}`,
  or `{:cancel, reason}`.
  """
  def dispatch(%Coroutine.ExternalSuspended{value: value}), do: {:yield, value}
  def dispatch(%Coroutine.Completed{result: result}), do: {:complete, result}

  def dispatch(%Coroutine.Errored{error: %Coroutine.Error{type: :throw, error: error}}),
    do: {:error, error}

  def dispatch(%Coroutine.Errored{error: error}), do: {:error, error}
  def dispatch(%Coroutine.Cancelled{reason: reason}), do: {:cancel, reason}
end
