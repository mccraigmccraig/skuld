defmodule Skuld.PageMachine do
  @moduledoc """
  LiveView integration for FiberPool.Server — a multi-fiber page machine
  with bidirectional message passing.

  ## Usage

      use Skuld.PageMachine,
        tag: :checkout,
        on_yield: &handle_yield/2,
        on_complete: &handle_complete/2

  ## Multi-spindle mode

  For pages with concurrent spindles, use `/3` callbacks:

      on_yield: &handle_yield/3

      defp handle_yield(:cart, status, socket), do: ...
      defp handle_yield(:checkout, step, socket), do: ...

  ## Event routing

  Events route to spindles by name:

      def_pipe_event "search", into: :products, before: &start_spinner/1
      def_pipe_event "buy", into: :products
  """

  alias Skuld.FiberPool.Server, as: FiberServer

  @default_tag Module.concat(__MODULE__, Default)
  @default_assign_key Module.concat(__MODULE__, DefaultAssign)

  @doc "The default PageMachine tag."
  def default_tag, do: @default_tag

  @doc "The default assign key used to look up the PageMachine pid from socket.assigns."
  def default_assign_key, do: @default_assign_key

  @doc """
  Start a page machine in a separate FiberPool.Server process.

  Takes a keyword list of `{spindle_key, computation}` pairs:

      PageMachine.run(products: ProductBrowserSpindle.run(%{}))

  Multiple spindles can be started at once:

      PageMachine.run(products: product_comp, checkout: checkout_comp)

  ## Options

  - `:tag` — the PMC tag for message routing. Defaults to
    `Skuld.PageMachine.Default`. Only needed for multi-PMC pages.
  """
  def run(fibers, _opts \\ []) when is_list(fibers) do
    FiberServer.start_link(fibers)
  end

  @doc "Resume a yielded spindle with a value."
  def resume(pid, fiber_key, value) do
    FiberServer.resume(pid, fiber_key, value)
  end

  @doc "Cancel a running page machine and all its spindles."
  def cancel(pid) do
    Process.exit(pid, :normal)
  end

  #############################################################################
  ## def_pipe_event macros
  #############################################################################

  defmacro def_pipe_event(event, opts \\ []) do
    generate_clause(event, nil, opts)
  end

  defmacro def_pipe_event(event, pattern, opts) do
    generate_clause(event, pattern, opts)
  end

  defp generate_clause(event, pattern, opts) do
    into = Keyword.get(opts, :into)
    before = Keyword.get(opts, :before)
    assign_key = Keyword.get(opts, :assign, @default_assign_key)
    block = Keyword.get(opts, :do)

    body =
      case pattern do
        nil ->
          quote do
            def handle_event(unquote(event), params, socket) do
              unquote(before_call(before))

              Skuld.PageMachine.resume(
                Map.fetch!(socket.assigns, unquote(assign_key)),
                unquote(into),
                {unquote(event), params}
              )

              {:noreply, socket}
            end
          end

        _ ->
          quote do
            def handle_event(unquote(event), unquote(pattern), socket) do
              unquote(before_call(before))

              value = unquote(block)

              Skuld.PageMachine.resume(
                Map.fetch!(socket.assigns, unquote(assign_key)),
                unquote(into),
                value
              )

              {:noreply, socket}
            end
          end
      end

    body
  end

  defp before_call(nil), do: nil
  defp before_call(callback), do: quote(do: socket = unquote(callback).(socket))

  #############################################################################
  ## __using__ macro
  #############################################################################

  defmacro __using__(opts) do
    tag = Keyword.get(opts, :tag, @default_tag)
    on_yield_ref = Keyword.fetch!(opts, :on_yield)
    on_complete = Keyword.get(opts, :on_complete)
    on_error = Keyword.get(opts, :on_error)
    on_cancel = Keyword.get(opts, :on_cancel)
    on_throw = Keyword.get(opts, :on_throw)

    yield_arity = callback_arity(on_yield_ref)

    clauses =
      [
        build_clause(
          on_yield_ref,
          yield_arity,
          quote(do: %Skuld.Comp.ExternalSuspend{value: value}),
          quote(do: value)
        ),
        if(on_error,
          do: build_clause(on_error, 2, quote(do: {:error, reason}), quote(do: reason))
        ),
        if(on_cancel,
          do:
            build_clause(
              on_cancel,
              2,
              quote(do: %Skuld.Comp.Cancelled{reason: reason}),
              quote(do: reason)
            )
        ),
        if(on_throw,
          do:
            build_clause(
              on_throw,
              2,
              quote(do: %Skuld.Comp.Throw{error: error}),
              quote(do: error)
            )
        ),
        if(on_complete,
          do: build_clause(on_complete, 2, quote(do: value), quote(do: value))
        )
      ]
      |> Enum.filter(& &1)

    quote do
      @pmc_tag unquote(tag)
      @pmc_assign_key unquote(@default_assign_key)

      import Skuld.PageMachine,
        only: [def_pipe_event: 1, def_pipe_event: 2, def_pipe_event: 3]

      (unquote_splicing(clauses))
    end
  end

  defp callback_arity({:&, _, [{:/, _, [{_name, _, nil}, arity]}]}), do: arity
  defp callback_arity(_), do: 2

  defp build_clause(callback_ref, arity, pattern, value_expr) do
    callback = callback_ref

    if arity == 3 do
      quote do
        def handle_info(
              {Skuld.FiberPool.Server, fiber_key, unquote(pattern)},
              socket
            ) do
          unquote(callback).(fiber_key, unquote(value_expr), socket)
        end
      end
    else
      quote do
        def handle_info(
              {Skuld.FiberPool.Server, @pmc_tag, unquote(pattern)},
              socket
            ) do
          unquote(callback).(unquote(value_expr), socket)
        end
      end
    end
  end
end
