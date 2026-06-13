defmodule Skuld.Coroutine.PageMachine do
  @moduledoc """
  Synchronous page-machine for effectful state machines.

  Two APIs: a pure API returning tagged tuples (for testing), and a
  callback-based API returning `{:noreply, socket}` (for LiveView).

  ## Pure API (testing)

      {:yield, fiber, :shipping} = PageMachine.run(MyApp.CheckoutFlow.flow(cart))
      {:yield, fiber, :payment} = PageMachine.run(fiber, {:ok, %{address: "123"}})
      {:complete, {:ok, order}} = PageMachine.run(fiber, {:ok, %{card: "4242"}})

  ## Callback API (LiveView)

      pm = PageMachine.run(MyApp.CheckoutFlow.flow(cart), socket,
        on_yield: fn step, socket -> {:noreply, assign(socket, step: step)} end,
        on_complete: fn {:ok, order}, socket -> {:noreply, assign(socket, order: order, step: :done)} end,
        on_error: fn reason, socket -> {:noreply, put_flash(socket, :error, inspect(reason))} end,
        on_cancel: fn reason, socket -> {:noreply, push_navigate(socket, to: ~p"/cart")} end
      )
      {:ok, socket} = PageMachine.run(pm, {:ok, %{address: "123"}}, socket)

  The callback API stores the fiber internally — callbacks never see it.
  For cross-process use, see `Skuld.AsyncCoroutine.AsyncPageMachine`.
  """

  alias Skuld.Comp.Env
  alias Skuld.Coroutine

  defstruct [:fiber, :on_yield, :on_complete, :on_error, :on_cancel]

  @typedoc """
  A page machine carrying the current fiber and callback functions.
  Stored in `socket.assigns.pm` between calls.
  """
  @type t :: %__MODULE__{
          fiber: Coroutine.ExternalSuspended.t(),
          on_yield: (term(), map() -> term()),
          on_complete: (term(), map() -> term()) | nil,
          on_error: (term(), map() -> term()) | nil,
          on_cancel: (term(), map() -> term()) | nil
        }

  # ===========================================================================
  # Pure API — tagged tuples (testing)
  # ===========================================================================

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

  def cancel(var, reason \\ :cancelled)

  def cancel({:yield, fiber, _value}, reason) do
    dispatch(fiber |> Coroutine.cancel(reason))
  end

  def cancel(%Coroutine.ExternalSuspended{} = fiber, reason) do
    dispatch(fiber |> Coroutine.cancel(reason))
  end

  @doc """
  Cancel a page machine. Dispatches through `on_cancel` if available.

  Returns `{:noreply, socket}`.
  """
  def cancel(%__MODULE__{} = pm, reason) do
    fiber = pm.fiber |> Coroutine.cancel(reason)
    dispatch_callback(%{pm | fiber: fiber}, {:cancel, reason})
  end

  defp dispatch(%Coroutine.ExternalSuspended{value: value} = fiber), do: {:yield, fiber, value}
  defp dispatch(%Coroutine.Completed{result: result}), do: {:complete, result}

  defp dispatch(%Coroutine.Errored{error: %Coroutine.Error{type: :throw, error: error}}),
    do: {:error, error}

  defp dispatch(%Coroutine.Errored{error: error}), do: {:error, error}
  defp dispatch(%Coroutine.Cancelled{reason: reason}), do: {:cancel, reason}

  # ===========================================================================
  # Callback API — {:noreply, socket} (LiveView)
  # ===========================================================================

  @doc """
  Start a page machine with callbacks. Runs the first step of the
  computation and dispatches the result through the appropriate callback.

  Callbacks:
  - `:on_yield` (required) — `(value, socket) -> {:noreply, socket}`
  - `:on_complete` — `(result, socket) -> {:noreply, socket}`
  - `:on_error` — `(error, socket) -> {:noreply, socket}`
  - `:on_cancel` — `(reason, socket) -> {:noreply, socket}`

  Returns `{:noreply, socket}`. Stores the page machine in
  `socket.assigns.pm` for subsequent `run/3` calls.
  """
  def run(computation, socket, callbacks) when is_function(computation, 2) and is_list(callbacks) do
    pm = %__MODULE__{
      fiber: computation |> Coroutine.new(Env.new()) |> Coroutine.run(),
      on_yield: Keyword.fetch!(callbacks, :on_yield),
      on_complete: Keyword.get(callbacks, :on_complete),
      on_error: Keyword.get(callbacks, :on_error),
      on_cancel: Keyword.get(callbacks, :on_cancel)
    }

    dispatch_callback(pm, socket)
  end

  def run(%__MODULE__{fiber: fiber} = pm, value, socket) do
    resolved =
      case fiber do
        {:yield, fiber, _value} -> fiber |> Coroutine.run(value)
        fiber -> fiber |> Coroutine.run(value)
      end

    dispatch_callback(%{pm | fiber: resolved}, socket)
  end

  defp dispatch_callback(
         %__MODULE__{fiber: %Coroutine.ExternalSuspended{value: v}} = pm,
         socket
       ) do
    result = pm.on_yield.(v, socket)
    store(pm, result)
  end

  defp dispatch_callback(%__MODULE__{on_complete: nil}, socket), do: {:noreply, socket}

  defp dispatch_callback(%__MODULE__{fiber: %Coroutine.Completed{result: r}} = pm, socket) do
    pm.on_complete.(r, socket)
  end

  defp dispatch_callback(
         %__MODULE__{fiber: %Coroutine.Errored{error: %Coroutine.Error{type: :throw, error: e}}} = pm,
         socket
       ) do
    if pm.on_error, do: pm.on_error.(e, socket), else: {:noreply, socket}
  end

  defp dispatch_callback(%__MODULE__{fiber: %Coroutine.Errored{error: error}} = pm, socket) do
    if pm.on_error, do: pm.on_error.(error, socket), else: {:noreply, socket}
  end

  defp dispatch_callback(%__MODULE__{fiber: %Coroutine.Cancelled{reason: reason}} = pm, socket) do
    if pm.on_cancel, do: pm.on_cancel.(reason, socket), else: {:noreply, socket}
  end

  defp store(pm, {:noreply, socket}) do
    {:noreply, %{socket | assigns: Map.put(socket.assigns, :pm, pm)}}
  end
end
