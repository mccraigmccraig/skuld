defmodule Skuld.PageMachine.SyncPageMachine do
  @moduledoc """
  Synchronous page-machine for LiveView integration.

  Wraps `Skuld.Coroutine` with a callback-based API. Callbacks are
  provided once at mount; subsequent resumes are one-liners. The fiber
  is stored in `socket.assigns.pm` automatically — callbacks never see it.

  ## Example

      alias Skuld.PageMachine.SyncPageMachine

      # mount — one-time setup
      SyncPageMachine.run(MyApp.CheckoutFlow.flow(cart), socket, :checkout,
        on_yield: fn step, socket -> {:noreply, assign(socket, step: step)} end,
        on_complete: fn {:ok, order}, socket -> {:noreply, assign(socket, order: order, step: :done)} end,
        on_error: fn reason, socket -> {:noreply, put_flash(socket, :error, inspect(reason))} end,
        on_cancel: fn reason, socket -> {:noreply, push_navigate(socket, to: ~p"/cart")} end
      )

      # handle_event — one-liner
      def handle_event("submit", %{"value" => v}, socket),
        do: SyncPageMachine.run(socket.assigns.checkout, {:ok, v}, socket)

  For cross-process use, see `Skuld.PageMachine.AsyncPageMachine`.
  """

  alias Skuld.Comp.Env
  alias Skuld.Coroutine

  defstruct [:fiber, :assign_key, :on_yield, :on_complete, :on_error, :on_cancel]

  @typedoc """
  A page machine carrying the current fiber and callback functions.
  Stored in `socket.assigns[key]` between calls.
  """
  @type t :: %__MODULE__{
          fiber: Coroutine.ExternalSuspended.t(),
          assign_key: atom(),
          on_yield: (term(), map() -> term()),
          on_complete: (term(), map() -> term()) | nil,
          on_error: (term(), map() -> term()) | nil,
          on_cancel: (term(), map() -> term()) | nil
        }

  @doc """
  Start a page machine with callbacks. Runs the first step of the
  computation and dispatches the result through the appropriate callback.

  The page machine struct is stored in `socket.assigns[key]`.

  Callbacks:
  - `:on_yield` (required) — `(value, socket) -> {:noreply, socket}`
  - `:on_complete` — `(result, socket) -> {:noreply, socket}`
  - `:on_error` — `(error, socket) -> {:noreply, socket}`
  - `:on_cancel` — `(reason, socket) -> {:noreply, socket}`

  Returns `{:noreply, socket}`.
  """
  def run(computation, socket, key, callbacks)
      when is_function(computation, 2) and is_atom(key) and is_list(callbacks) do
    pm = %__MODULE__{
      fiber: computation |> Coroutine.new(Env.new()) |> Coroutine.run(),
      assign_key: key,
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
  Imports `def_pipe_event/2` and `def_pipe_event/4` into the caller so
  they can be used without module prefix.
  """
  defmacro __using__(_opts) do
    quote do
      import Skuld.PageMachine.SyncPageMachine,
        only: [def_pipe_event: 2, def_pipe_event: 3, def_pipe_event: 4]
    end
  end

  @doc """
  Generate a `handle_event/3` clause that pipes a Phoenix event into the
  PageMachine as a Yield resume value. Multiple `def_pipe_event` calls produce
  multiple `handle_event/3` clauses — one per event name.

  ## Options

  - `:before` — an optional `(socket -> socket)` callback called before the
    event is piped to the PageMachine. Useful for setting a loading spinner.

  ## Without pattern matching

      def_pipe_event "submit_payment", :runner
      def_pipe_event "submit_payment", :runner, before: &start_spinner/1

  Generates:

      def handle_event("submit_payment", params, socket) do
        socket = start_spinner(socket)
        PageMachine.run(socket.assigns[:runner], {"submit_payment", params}, socket)
      end

  ## With pattern matching and transformation

      def_pipe_event "submit_shipping", :runner, %{"address" => addr}, before: &start_spinner/1 do
        {:ok, %{address: addr}}
      end

  Generates:

      def handle_event("submit_shipping", %{"address" => addr}, socket) do
        socket = start_spinner(socket)
        PageMachine.run(socket.assigns[:runner], {:ok, %{address: addr}}, socket)
      end
  """
  defmacro def_pipe_event(event, assign_key) do
    pipe_before = nil

    quote do
      def handle_event(unquote(event), params, socket) do
        unquote(build_before(pipe_before))

        Skuld.PageMachine.SyncPageMachine.run(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          {unquote(event), params},
          socket
        )
      end
    end
  end

  defmacro def_pipe_event(event, assign_key, before: before) do
    quote do
      def handle_event(unquote(event), params, socket) do
        unquote(build_before(before))

        Skuld.PageMachine.SyncPageMachine.run(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          {unquote(event), params},
          socket
        )
      end
    end
  end

  @doc """
  Generate a `handle_event/3` clause with params pattern matching, a
  value-transformation block, and optional `:before` callback.
  """
  defmacro def_pipe_event(event, assign_key, pattern, do: block) do
    pipe_before = nil

    quote do
      def handle_event(unquote(event), unquote(pattern), socket) do
        unquote(build_before(pipe_before))
        value = unquote(block)

        Skuld.PageMachine.SyncPageMachine.run(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          value,
          socket
        )
      end
    end
  end

  defmacro def_pipe_event(event, assign_key, pattern, do: block, before: before) do
    quote do
      def handle_event(unquote(event), unquote(pattern), socket) do
        unquote(build_before(before))
        value = unquote(block)

        Skuld.PageMachine.SyncPageMachine.run(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          value,
          socket
        )
      end
    end
  end

  defp build_before(nil), do: nil
  defp build_before(callback), do: quote(do: socket = unquote(callback).(socket))

  @doc """
  Cancel a page machine. Dispatches through `on_cancel` if available.

  Returns `{:noreply, socket}`.
  """
  def cancel(%__MODULE__{} = pm, socket, reason \\ :cancelled) do
    fiber = pm.fiber |> Coroutine.cancel(reason)
    dispatch(%{pm | fiber: fiber}, socket)
  end

  defp dispatch(%__MODULE__{fiber: %Coroutine.ExternalSuspended{value: v}} = pm, socket) do
    result = pm.on_yield.(v, socket)
    store(pm, result)
  end

  defp dispatch(%__MODULE__{fiber: %Coroutine.Completed{result: r}} = pm, socket) do
    result = if pm.on_complete, do: pm.on_complete.(r, socket), else: {:noreply, socket}
    store(pm, result)
  end

  defp dispatch(
         %__MODULE__{fiber: %Coroutine.Errored{error: %Coroutine.Error{type: :throw, error: e}}} =
           pm,
         socket
       ) do
    result = if pm.on_error, do: pm.on_error.(e, socket), else: {:noreply, socket}
    store(pm, result)
  end

  defp dispatch(%__MODULE__{fiber: %Coroutine.Errored{error: error}} = pm, socket) do
    result = if pm.on_error, do: pm.on_error.(error, socket), else: {:noreply, socket}
    store(pm, result)
  end

  defp dispatch(%__MODULE__{fiber: %Coroutine.Cancelled{reason: reason}} = pm, socket) do
    result = if pm.on_cancel, do: pm.on_cancel.(reason, socket), else: {:noreply, socket}
    store(pm, result)
  end

  defp store(pm, {:noreply, socket}) do
    {:noreply, %{socket | assigns: Map.put(socket.assigns, pm.assign_key, pm)}}
  end
end
