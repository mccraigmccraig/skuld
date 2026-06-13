defmodule Skuld.Coroutine.PageMachine do
  @moduledoc """
  Synchronous page-machine for LiveView integration.

  Wraps `Skuld.Coroutine` with a callback-based API. Callbacks are
  provided once at mount; subsequent resumes are one-liners. The fiber
  is stored in `socket.assigns.pm` automatically — callbacks never see it.

  ## Example

      alias Skuld.Coroutine.PageMachine

      # mount — one-time setup
      PageMachine.run(MyApp.CheckoutFlow.flow(cart), socket,
        on_yield: fn step, socket -> {:noreply, assign(socket, step: step)} end,
        on_complete: fn {:ok, order}, socket -> {:noreply, assign(socket, order: order, step: :done)} end,
        on_error: fn reason, socket -> {:noreply, put_flash(socket, :error, inspect(reason))} end,
        on_cancel: fn reason, socket -> {:noreply, push_navigate(socket, to: ~p"/cart")} end
      )

      # handle_event — one-liner
      def handle_event("submit", %{"value" => v}, socket),
        do: PageMachine.run(socket.assigns.pm, {:ok, v}, socket)

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
  def run(computation, socket, callbacks)
      when is_function(computation, 2) and is_list(callbacks) do
    pm = %__MODULE__{
      fiber: computation |> Coroutine.new(Env.new()) |> Coroutine.run(),
      on_yield: Keyword.fetch!(callbacks, :on_yield),
      on_complete: Keyword.get(callbacks, :on_complete),
      on_error: Keyword.get(callbacks, :on_error),
      on_cancel: Keyword.get(callbacks, :on_cancel)
    }

    dispatch(pm, socket)
  end

  def run(%__MODULE__{fiber: fiber} = pm, value, socket) do
    resolved =
      case fiber do
        {:yield, fiber, _value} -> fiber |> Coroutine.run(value)
        fiber -> fiber |> Coroutine.run(value)
      end

    dispatch(%{pm | fiber: resolved}, socket)
  end

  @doc """
  Cancel a page machine. Dispatches through `on_cancel` if available.

  Returns `{:noreply, socket}`.
  """
  def cancel(%__MODULE__{} = pm, reason \\ :cancelled) do
    fiber = pm.fiber |> Coroutine.cancel(reason)
    dispatch(%{pm | fiber: fiber}, {:cancel, reason})
  end

  defp dispatch(%__MODULE__{fiber: %Coroutine.ExternalSuspended{value: v}} = pm, socket) do
    result = pm.on_yield.(v, socket)
    store(pm, result)
  end

  defp dispatch(%__MODULE__{fiber: %Coroutine.Completed{result: r}} = pm, socket) do
    if pm.on_complete, do: pm.on_complete.(r, socket), else: {:noreply, socket}
  end

  defp dispatch(
         %__MODULE__{fiber: %Coroutine.Errored{error: %Coroutine.Error{type: :throw, error: e}}} =
           pm,
         socket
       ) do
    if pm.on_error, do: pm.on_error.(e, socket), else: {:noreply, socket}
  end

  defp dispatch(%__MODULE__{fiber: %Coroutine.Errored{error: error}} = pm, socket) do
    if pm.on_error, do: pm.on_error.(error, socket), else: {:noreply, socket}
  end

  defp dispatch(%__MODULE__{fiber: %Coroutine.Cancelled{reason: reason}} = pm, socket) do
    if pm.on_cancel, do: pm.on_cancel.(reason, socket), else: {:noreply, socket}
  end

  defp store(pm, {:noreply, socket}) do
    {:noreply, %{socket | assigns: Map.put(socket.assigns, :pm, pm)}}
  end
end
