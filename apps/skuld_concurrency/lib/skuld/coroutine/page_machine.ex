defmodule Skuld.Coroutine.PageMachine do
  @moduledoc """
  Synchronous page-machine for effectful state machines.

  Wraps `Skuld.Coroutine`, returning tagged tuples with the fiber embedded
  in the `:yield` case so callers can resume without an extra conversion
  step. For cross-process use (e.g. LiveView), see
  `Skuld.AsyncCoroutine.AsyncPageMachine`.

  ## Example

      alias Skuld.Coroutine.PageMachine

      # Start
      {:yield, fiber, :shipping} = PageMachine.run(MyApp.CheckoutFlow.flow(cart))

      # Resume
      {:yield, fiber, :payment} = PageMachine.run(fiber, {:ok, %{address: "123 Main"}})

      # Complete
      {:complete, {:ok, order}} = PageMachine.run(fiber, {:ok, %{card: "4242"}})

  ## Return values

  - `{:yield, fiber, value}` — computation yielded, waiting for input
  - `{:complete, result}` — computation finished successfully
  - `{:error, reason}` — computation threw or errored
  - `{:cancel, reason}` — computation was cancelled
  """

  alias Skuld.Comp.Env
  alias Skuld.Coroutine

  @doc """
  Start a computation. Returns a tagged tuple.
  """
  def run(computation) when is_function(computation, 2) do
    dispatch(computation |> Coroutine.new(Env.new()) |> Coroutine.run())
  end

  def run(%Coroutine.ExternalSuspended{} = fiber) do
    dispatch(fiber)
  end

  def run({:yield, fiber, _value}, value) do
    dispatch(fiber |> Coroutine.run(value))
  end

  def run(%Coroutine.ExternalSuspended{} = fiber, value) do
    dispatch(fiber |> Coroutine.run(value))
  end

  @doc """
  Cancel a computation from a `{:yield, fiber, _}` tuple or raw fiber.

  Returns `{:cancel, reason}`.
  """
  def cancel(fiber, reason \\ :cancelled)

  def cancel({:yield, fiber, _value}, reason) do
    dispatch(fiber |> Coroutine.cancel(reason))
  end

  def cancel(%Coroutine.ExternalSuspended{} = fiber, reason) do
    dispatch(fiber |> Coroutine.cancel(reason))
  end

  defp dispatch(%Coroutine.ExternalSuspended{value: value} = fiber), do: {:yield, fiber, value}
  defp dispatch(%Coroutine.Completed{result: result}), do: {:complete, result}

  defp dispatch(%Coroutine.Errored{error: %Coroutine.Error{type: :throw, error: error}}),
    do: {:error, error}

  defp dispatch(%Coroutine.Errored{error: error}), do: {:error, error}
  defp dispatch(%Coroutine.Cancelled{reason: reason}), do: {:cancel, reason}
end
