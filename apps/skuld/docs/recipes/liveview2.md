# Concurrent Spindles

<!-- nav:header:start -->
[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Durable Computation >](durable-computation.md)
<!-- nav:header:end -->

`AsyncPageMachine` runs multiple concurrent spindles within a single page —
each spindle is an independent state machine with its own fiber, its own
event stream, and its own yields to the LiveView.

## When to use concurrent spindles

A page with a product browser and a checkout form side by side. The product
browser has its own lifecycle (search, filter, paginate) independent of the
checkout flow (collect shipping, collect payment, place order). Running them
as separate spindles keeps each flow linear and testable in isolation.

## Example: product browser + checkout

Two spindles running in the same page machine:

| Spindle | Role | Event source |
|---------|------|-------------|
| `:products` | Forever loop: accept filter params, query products, yield results | `"search"`, `"filter"`, `"page"` events |
| `:checkout` | Linear flow: collect shipping, collect payment, place order | `"submit_shipping"`, `"submit_payment"` events |

### Boundary contracts

```elixir
defmodule MyApp.ProductCatalog do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback search(filters :: map(), page :: integer()) ::
              {:ok, [Product.t()], total :: integer()} | {:error, term()}
end

defmodule MyApp.Orders do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback place(cart :: Cart.t(), shipping :: map(), payment :: map()) ::
              {:ok, Order.t()} | {:error, term()}
end

defmodule MyApp.Inventory do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback reserve(cart :: Cart.t()) :: {:ok, term()} | {:error, term()}
end
```

### Spindle computations

The product browser spindle runs forever — each search yields results, then
loops back for the next filter change:

```elixir
defmodule MyApp.ProductBrowserSpindle do
  use Skuld.Syntax

  alias Skuld.Effects.Yield

  defcomp run(initial_filters) do
    search_loop(initial_filters, 1)
  end

  defcomp search_loop(filters, page) do
    {:ok, products, total} <- MyApp.ProductCatalog.search(filters, page)
    new_filters <- Yield.yield({:results, products, total, page})
    search_loop(new_filters, 1)
  end
end
```

The checkout spindle is the same linear flow from the previous example:

```elixir
defmodule MyApp.CheckoutSpindle do
  use Skuld.Syntax

  alias Skuld.Effects.Yield

  defcomp run(cart) do
    {:ok, _} <- MyApp.Inventory.reserve(cart)
    {"submit_shipping", shipping} <- Yield.yield(:shipping)
    {"submit_payment", payment} <- Yield.yield(:payment)
    {:ok, order} <- MyApp.Orders.place(cart, shipping, payment)
    {:ok, order}
  else
    {:error, :sold_out} -> {:error, :sold_out}
    {:error, reason} -> {:error, reason}
  end
end
```

### LiveView module

Note the `/3` callbacks — each handler receives the spindle key as its
first argument, allowing a single callback to dispatch by spindle:

```elixir
defmodule MyApp.StoreLive do
  use MyAppWeb, :live_view
  use Skuld.PageMachine.AsyncPageMachine,
    tag: :checkout,
    on_yield: &handle_yield/3,
    on_complete: &handle_complete/3,
    on_error: &handle_error/3

  @impl true
  def mount(_params, _session, socket) do
    {:ok, runner} =
      AsyncPageMachine.run(
        MyApp.CheckoutSpindle.run(socket.assigns.cart),
        :checkout
      )

    # Fork the product browser spindle
    FiberPool.Server.start_link(
      [{:products, MyApp.ProductBrowserSpindle.run(%{})}],
      runner
    )

    {:ok,
     assign(socket,
       runner: runner,
       step: :loading,
       products: [],
       total: 0,
       page: 1
     )}
  end

  # Multi-spindle callbacks — dispatch by spindle key
  defp handle_yield(:products, {:results, products, total, page}, socket) do
    {:noreply, assign(socket, products: products, total: total, page: page)}
  end

  defp handle_yield(:checkout, step, socket) do
    socket = clear_spinner(socket)
    {:noreply, assign(socket, step: step)}
  end

  defp handle_complete(:checkout, {:ok, order}, socket) do
    socket = clear_spinner(socket)
    {:noreply, assign(socket, order: order, step: :done)}
  end

  defp handle_complete(:products, {:error, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Product search failed: #{inspect(reason)}")}
  end

  defp handle_error(:checkout, :sold_out, socket) do
    socket = clear_spinner(socket)
    {:noreply, put_flash(socket, :error, "Sorry, this item is no longer available")}
  end

  defp handle_error(:checkout, reason, socket) do
    socket = clear_spinner(socket)
    {:noreply, put_flash(socket, :error, "Checkout failed: #{inspect(reason)}")}
  end

  defp start_spinner(socket), do: assign(socket, :loading, true)
  defp clear_spinner(socket), do: assign(socket, :loading, false)

  # Product browser events — routed to :products spindle
  def_pipe_event "search", :runner, into: :products, before: &start_spinner/1
  def_pipe_event "filter", :runner, into: :products, before: &start_spinner/1
  def_pipe_event "page", :runner, into: :products, before: &start_spinner/1

  # Checkout events — default to :checkout (the PMC tag)
  def_pipe_event "submit_shipping", :runner, before: &start_spinner/1
  def_pipe_event "submit_payment", :runner, before: &start_spinner/1

  @impl true
  def render(assigns) do
    ~H"""
    <div class="store-layout">
      <div class="product-browser">
        <.search_form myself={@myself} loading={@loading} />
        <.product_list products={@products} page={@page} total={@total} myself={@myself} />
      </div>
      <div class="checkout-panel">
        <%= case @step do %>
          <% :shipping -> %>
            <.shipping_form loading={@loading} myself={@myself} />
          <% :payment -> %>
            <.payment_form loading={@loading} myself={@myself} />
          <% :done -> %>
            <.order_summary order={@order} />
          <% _ -> %>
            <.spinner />
        <% end %>
      </div>
    </div>
    """
  end
end
```

### Testing in isolation

Each spindle is tested independently with `Coroutine`:

```elixir
defmodule MyApp.ProductBrowserSpindleTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp.Env
  alias Skuld.Coroutine
  alias Skuld.Effects.Yield

  setup do
    comp =
      MyApp.ProductBrowserSpindle.run(%{category: "electronics"})
      |> Port.with_handler(%{
        MyApp.ProductCatalog => fn _, :search, [%{category: "electronics"}, 1] ->
          {:ok, [%Product{name: "Phone"}], 1}
        end
      })
      |> Yield.with_handler()

    {:ok, comp: comp}
  end

  test "first search yields products", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    assert %Coroutine.ExternalSuspended{
             value: {:results, [%Product{name: "Phone"}], 1, 1}
           } = fiber
  end

  test "filter change triggers new search", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    # Send new filter params — triggers loop with new search
    # (would need a new Port handler for the new filter)
    _fiber = Coroutine.run(fiber, %{category: "books"})
  end
end
```

## How the spindles collaborate

Each spindle is an independent coroutine. The product spindle loops forever:
yield results, wait for new filters, query again. The checkout spindle runs
once: collect inputs, place order, exit. Both run concurrently in the same
FiberPool.Server process — cooperatively scheduled, no locking. The `/3`
callbacks route each yield to the right UI region.

The product browser spindle never blocks the checkout spindle. When the
user types a search, the product spindle suspends while the query runs
(inside `Port.call`), and the FiberPool scheduler runs the checkout
spindle's continuation instead. Both progress independently.

## Comparison to a monolithic LiveView

Without spindles, the product browser and checkout form would share a single
`handle_event`. Filter changes, pagination, shipping collection, and payment
collection would all live in the same callback function, tangled with
socket-assign manipulation. Adding a third region (say, a recommendations
carousel) would require more conditional logic in the same flat handler.

With spindles, each region is a self-contained computation. Adding a
recommendations carousel is a new spindle and a `/3` callback clause. The
existing spindles don't change.

<!-- nav:footer:start -->

---

[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Durable Computation >](durable-computation.md)
<!-- nav:footer:end -->
