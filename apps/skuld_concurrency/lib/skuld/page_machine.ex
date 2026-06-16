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

  By default, events go to the main fiber (the PMC tag). Use `into:`
  to route to a specific spindle:

      def_pipe_event "add_to_cart", :runner, into: :cart
      def_pipe_event "submit_shipping", :runner
  """

  alias Skuld.FiberPool.Server, as: FiberServer

  @doc "Start a page machine in a separate FiberPool.Server process."
  def run(computation, tag) when is_function(computation, 2) do
    FiberServer.start_link([{tag, computation}])
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

  defmacro def_pipe_event(event, assign_key) do
    into = nil
    pmc_tag = Module.get_attribute(__CALLER__.module, :pmc_tag)

    quote do
      def handle_event(unquote(event), params, socket) do
        fiber_key = unquote(into) || unquote(pmc_tag) || unquote(assign_key)

        Skuld.PageMachine.resume(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          fiber_key,
          {unquote(event), params}
        )

        {:noreply, socket}
      end
    end
  end

  defmacro def_pipe_event(event, assign_key, before: before) do
    into = nil
    pmc_tag = Module.get_attribute(__CALLER__.module, :pmc_tag)

    quote do
      def handle_event(unquote(event), params, socket) do
        socket = unquote(before).(socket)
        fiber_key = unquote(into) || unquote(pmc_tag) || unquote(assign_key)

        Skuld.PageMachine.resume(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          fiber_key,
          {unquote(event), params}
        )

        {:noreply, socket}
      end
    end
  end

  defmacro def_pipe_event(event, assign_key, pattern, do: block) do
    into = nil
    pmc_tag = Module.get_attribute(__CALLER__.module, :pmc_tag)

    quote do
      def handle_event(unquote(event), unquote(pattern), socket) do
        fiber_key = unquote(into) || unquote(pmc_tag) || unquote(assign_key)
        value = unquote(block)

        Skuld.PageMachine.resume(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          fiber_key,
          value
        )

        {:noreply, socket}
      end
    end
  end

  defmacro def_pipe_event(event, assign_key, pattern, do: block, before: before) do
    into = nil
    pmc_tag = Module.get_attribute(__CALLER__.module, :pmc_tag)

    quote do
      def handle_event(unquote(event), unquote(pattern), socket) do
        socket = unquote(before).(socket)
        fiber_key = unquote(into) || unquote(pmc_tag) || unquote(assign_key)
        value = unquote(block)

        Skuld.PageMachine.resume(
          Map.fetch!(socket.assigns, unquote(assign_key)),
          fiber_key,
          value
        )

        {:noreply, socket}
      end
    end
  end

  #############################################################################
  ## __using__ macro
  #############################################################################

  defmacro __using__(opts) do
    tag = Keyword.fetch!(opts, :tag)
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

      import Skuld.PageMachine,
        only: [def_pipe_event: 2, def_pipe_event: 3, def_pipe_event: 4]

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
