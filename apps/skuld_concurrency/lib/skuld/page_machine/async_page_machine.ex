defmodule Skuld.PageMachine.AsyncPageMachine do
  @moduledoc """
  Generates `handle_info/2` clauses that dispatch AsyncCoroutine messages
  into callback functions, eliminating LiveView boilerplate.

  No Phoenix dependency — just code generation. Use in any LiveView module
  that bridges an effectful page flow via `AsyncCoroutine`.

  ## Usage

      use Skuld.PageMachine.AsyncPageMachine,
        tag: :checkout,
        on_yield: &handle_yield/2,
        on_complete: &handle_complete/2

  ## Options

    * `:tag` (required) — the async coroutine tag atom
    * `:on_yield` (required) — `(value, socket) -> term()`
      Called when the computation yields via `ExternalSuspend`
    * `:on_complete` — `(result, socket) -> term()`
      Called when the computation completes
    * `:on_error` — `(error, socket) -> term()`
      Called on `{:error, reason}` results
    * `:on_cancel` — `(reason, socket) -> term()`
      Called when the computation is cancelled
    * `:on_throw` — `(error, socket) -> term()`
      Called when the computation throws

  If `on_error` is not given but `on_complete` is, `{:error, reason}`
  falls through to `on_complete`.
  """

  @doc """
  Start a page machine in a separate process. Delegates to `AsyncCoroutine.run/3`.

  The computation will have `Throw.with_handler/1` and `Yield.with_handler/1`
  added automatically. Add other handlers before calling `run`.

  Returns `{:ok, runner}` where the runner can be used with `run/3`
  to resume the flow with user input.
  """
  def run(computation, tag) when is_function(computation, 2),
    do: Skuld.AsyncCoroutine.run(computation, tag)

  def run(%Skuld.AsyncCoroutine{} = runner, value), do: run(runner, value, [])

  def run(computation, tag, opts) when is_function(computation, 2) do
    Skuld.AsyncCoroutine.run(computation, tag, opts)
  end

  @doc """
  Resume a yielded page machine with a value. Delegates to `AsyncCoroutine.run/3`.
  """
  def run(%Skuld.AsyncCoroutine{} = runner, value, opts) do
    Skuld.AsyncCoroutine.run(runner, value, opts)
  end

  @doc """
  Cancel a running page machine. Delegates to `AsyncCoroutine.cancel/1`.
  """
  def cancel(%Skuld.AsyncCoroutine{} = runner) do
    Skuld.AsyncCoroutine.cancel(runner)
  end

  @doc """
  Generate a `handle_event/3` clause that pipes a Phoenix event into the
  AsyncPageMachine as a Yield resume value. Multiple `def_pipe_event` calls
  produce multiple `handle_event/3` clauses — one per event name.

  Auto-imported when using `use AsyncPageMachine`.

  ## Options

  - `:before` — an optional `(socket -> socket)` callback called before the
    event is piped to the AsyncPageMachine. Useful for setting a loading spinner.

  ## Without pattern matching

      def_pipe_event "submit_payment", :runner
      def_pipe_event "submit_payment", :runner, before: &start_spinner/1

  Generates:

      def handle_event("submit_payment", params, socket) do
        socket = start_spinner(socket)
        AsyncPageMachine.run(socket.assigns[:runner], {"submit_payment", params})
        {:noreply, socket}
      end

  ## With pattern matching and transformation

      def_pipe_event "submit_shipping", :runner, %{"address" => addr}, before: &start_spinner/1 do
        {:ok, %{address: addr}}
      end

  Generates:

      def handle_event("submit_shipping", %{"address" => addr}, socket) do
        socket = start_spinner(socket)
        AsyncPageMachine.run(socket.assigns[:runner], {:ok, %{address: addr}})
        {:noreply, socket}
      end
  """
  defmacro def_pipe_event(event, assign_key) do
    pipe_before = nil

    quote do
      def handle_event(unquote(event), params, socket) do
        unquote(build_before(pipe_before))

        Skuld.PageMachine.AsyncPageMachine.run(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          {unquote(event), params}
        )

        {:noreply, socket}
      end
    end
  end

  defmacro def_pipe_event(event, assign_key, before: before) do
    quote do
      def handle_event(unquote(event), params, socket) do
        unquote(build_before(before))

        Skuld.PageMachine.AsyncPageMachine.run(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          {unquote(event), params}
        )

        {:noreply, socket}
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

        Skuld.PageMachine.AsyncPageMachine.run(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          value
        )

        {:noreply, socket}
      end
    end
  end

  defmacro def_pipe_event(event, assign_key, pattern, do: block, before: before) do
    quote do
      def handle_event(unquote(event), unquote(pattern), socket) do
        unquote(build_before(before))

        value = unquote(block)

        Skuld.PageMachine.AsyncPageMachine.run(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          value
        )

        {:noreply, socket}
      end
    end
  end

  defp build_before(nil), do: nil
  defp build_before(callback), do: quote(do: socket = unquote(callback).(socket))

  defmacro __using__(opts) do
    tag = Keyword.fetch!(opts, :tag)
    on_yield = Keyword.fetch!(opts, :on_yield)
    on_complete = Keyword.get(opts, :on_complete)
    on_error = Keyword.get(opts, :on_error)
    on_cancel = Keyword.get(opts, :on_cancel)
    on_throw = Keyword.get(opts, :on_throw)

    clauses =
      [
        build_clause(
          tag,
          on_yield,
          quote(do: %Skuld.Comp.ExternalSuspend{value: value}),
          quote(do: value)
        ),
        if(on_error,
          do: build_clause(tag, on_error, quote(do: {:error, reason}), quote(do: reason))
        ),
        if(on_cancel,
          do:
            build_clause(
              tag,
              on_cancel,
              quote(do: %Skuld.Comp.Cancelled{reason: reason}),
              quote(do: reason)
            )
        ),
        if(on_throw,
          do:
            build_clause(
              tag,
              on_throw,
              quote(do: %Skuld.Comp.Throw{error: error}),
              quote(do: error)
            )
        ),
        if(on_complete,
          do: build_clause(tag, on_complete, quote(do: value), quote(do: value))
        )
      ]
      |> Enum.filter(& &1)

    quote do
      import Skuld.PageMachine.AsyncPageMachine,
        only: [def_pipe_event: 2, def_pipe_event: 3, def_pipe_event: 4]

      (unquote_splicing(clauses))
    end
  end

  defp build_clause(tag, callback, pattern, arg) do
    quote do
      def handle_info(
            {Skuld.AsyncCoroutine, unquote(tag), unquote(pattern)},
            socket
          ) do
        unquote(callback).(unquote(arg), socket)
      end
    end
  end
end
