defmodule Skuld.AsyncCoroutine.PageMachine do
  @moduledoc """
  Generates `handle_info/2` clauses that dispatch AsyncCoroutine messages
  into callback functions, eliminating LiveView boilerplate.

  No Phoenix dependency — just code generation. Use in any LiveView module
  that bridges an effectful page flow via `AsyncCoroutine`.

  ## Usage

      use Skuld.AsyncCoroutine.PageMachine,
        tag: :checkout,
        on_yield: &handle_yield/2,
        on_complete: &handle_complete/2

  ## Options

    * `:tag` (required) — the async coroutine tag
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
  Start a page machine in a separate process. Delegates to `AsyncCoroutine.run/2`.

  The computation will have `Throw.with_handler/1` and `Yield.with_handler/1`
  added automatically. Add other handlers before calling `run`.

  Returns `{:ok, runner}` where the runner can be used with `AsyncCoroutine.run/3`
  to resume the flow with user input.
  """
  defdelegate run(computation, opts), to: Skuld.AsyncCoroutine

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
