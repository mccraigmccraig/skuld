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

  ## Typed contract

  For compile-time validation of the entire spindle ↔ LiveView contract,
  define a contract module with `use Skuld.PageMachine.Contract` and pass
  it via the `:contract` option:

      defmodule MyApp.StoreContract do
        use Skuld.PageMachine.Contract

        defevent "search", SearchEvent, params: [query: String.t()]
        defevent "buy", BuyEvent, params: [product: Product.t()]

        defyield :browsing
        defyield :results, params: [products: [Product.t()], total: integer()]
        defyield :checkout, :shipping
      end

      use Skuld.PageMachine,
        contract: MyApp.StoreContract,
        on_yield: &handle_yield/3

  The contract auto-generates `handle_event/3` clauses for each event,
  so manual `def_pipe_event` declarations are unnecessary (though still
  available for ad-hoc additions).
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

      {:ok, pid} = PageMachine.run(products: ProductBrowserSpindle.run(%{}))

  When a socket is passed as the first argument, the pid is stored
  automatically in `socket.assigns` under the default assign key
  (`Skuld.PageMachine.DefaultAssign`):

      socket =
        PageMachine.run(socket, products: ProductBrowserSpindle.run(%{}))

  Multiple spindles can be started at once:

      PageMachine.run(products: product_comp, checkout: checkout_comp)

  ## Options

  - `:tag` — the PMC tag for message routing. Defaults to
    `Skuld.PageMachine.Default`. Only needed for multi-PMC pages.
  """
  def run(fibers, _opts \\ [])

  def run(fibers, _opts) when is_list(fibers) do
    FiberServer.start_link(fibers)
  end

  def run(%{assigns: assigns} = socket, fibers) when is_list(fibers) do
    {:ok, pid} = FiberServer.start_link(fibers)
    %{socket | assigns: Map.put(assigns, @default_assign_key, pid)}
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
    contract = Keyword.get(opts, :contract)
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

    contract_clauses =
      if contract do
        contract = resolve_contract(contract, __CALLER__)

        contract.__contract_events__()
        |> Enum.map(fn %{
                         event: event_name,
                         spindle: spindle,
                         struct_name: struct_name,
                         params: params
                       } ->
          value =
            cond do
              struct_name && params != [] ->
                struct_module = Module.concat(spindle, struct_name)

                quote do
                  atom_params =
                    for {key, val} <- params, into: %{}, do: {String.to_existing_atom(key), val}

                  struct(unquote(struct_module), atom_params)
                end

              params != [] ->
                quote(do: params)

              true ->
                quote(do: {unquote(event_name), params})
            end

          quote do
            def handle_event(unquote(event_name), params, socket) do
              Skuld.PageMachine.resume(
                Map.fetch!(socket.assigns, @pmc_assign_key),
                unquote(spindle),
                unquote(value)
              )

              {:noreply, socket}
            end
          end
        end)
      else
        []
      end

    quote do
      @pmc_tag unquote(tag)
      @pmc_assign_key unquote(@default_assign_key)

      import Skuld.PageMachine,
        only: [def_pipe_event: 1, def_pipe_event: 2, def_pipe_event: 3]

      (unquote_splicing(clauses))
      (unquote_splicing(contract_clauses))
    end
  end

  defp resolve_contract(contract, caller) do
    contract = Macro.expand(contract, caller)

    unless Code.ensure_loaded?(contract) do
      raise CompileError,
        description:
          "Contract module #{inspect(contract)} is not loaded. " <>
            "Ensure it is compiled before the module using it.",
        file: caller.file,
        line: 0
    end

    unless function_exported?(contract, :__contract_events__, 0) do
      raise CompileError,
        description:
          "#{inspect(contract)} does not export __contract_events__/0. " <>
            "Did you `use Skuld.PageMachine.Contract`?",
        file: caller.file,
        line: 0
    end

    contract
  end

  defp callback_arity({:&, _, [{:/, _, [_, arity]}]}), do: arity
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
