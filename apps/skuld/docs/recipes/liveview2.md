# Concurrent Spindles

<!-- nav:header:start -->
[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Durable Computation >](durable-computation.md)
<!-- nav:header:end -->

`AsyncPageMachine` runs multiple concurrent spindles within a single page —
each spindle is an independent state machine with its own fiber, its own
event stream, and its own yields to the LiveView.

## When to use concurrent spindles

A page with a product browser and a checkout form side by side. The product
browser has its own lifecycle (search, filter, paginate, select product)
independent of the checkout flow (collect shipping, collect payment, place
order). Running them as separate spindles keeps each flow linear and testable
in isolation.

## Example: product browser + checkout

Two spindles running in the same page machine:

| Spindle | Role | Event source |
|---------|------|-------------|
| `:products` | Forever loop: search products, select one to buy | `"search"`, `"filter"`, `"page"` events |
| `:checkout` | Forked on buy: collect shipping, payment, place order | `"submit_shipping"`, `"submit_payment"` events |

### Boundary contracts

```elixir
defmodule MyApp.ProductCatalog do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback search(filters :: map(), page :: integer()) ::
              {:ok, [Product.t()], total :: integer()} | {:error, term()}
end

defmodule MyApp.Orders do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback place(cart :: map(), shipping :: map(), payment :: map()) ::
              {:ok, Order.t()} | {:error, term()}
end

defmodule MyApp.Inventory do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback reserve(cart :: map()) :: {:ok, term()} | {:error, term()}
end
```

### Spindle computations

The product browser spindle runs forever — each search yields results, then
loops for the next event. When the user clicks "buy," it forks a checkout
spindle and continues its own loop:

```elixir
defmodule MyApp.ProductBrowserSpindle do
  use Skuld.Syntax

  alias Skuld.Effects.Yield

  defcomp run(initial_filters) do
    search_loop(initial_filters, 1)
  end

  defcomp search_loop(filters, page) do
    {:ok, products, total} <- MyApp.ProductCatalog.search(filters, page)
    event <- Yield.yield(:browsing)

    case event do
      {:buy, product} ->
        _handle <- FiberPool.fiber(MyApp.CheckoutSpindle.run(product))
        Yield.yield({:buy, product})
        search_loop(filters, page)

      new_filters ->
        search_loop(new_filters, 1)
    end
  end
end
```

The checkout spindle is forked dynamically when the user selects a product.
It receives the product, reserves inventory, collects shipping and payment,
and places the order:

```elixir
defmodule MyApp.CheckoutSpindle do
  use Skuld.Syntax

  alias Skuld.Effects.Yield

  defcomp run(product) do
    {:ok, _} <- MyApp.Inventory.reserve(%{product: product})
    {"submit_shipping", shipping} <- Yield.yield(:shipping)
    {"submit_payment", payment} <- Yield.yield(:payment)
    {:ok, order} <- MyApp.Orders.place(%{product: product}, shipping, payment)
    {:ok, order}
  else
    {:error, :sold_out} -> {:error, :sold_out}
    {:error, reason} -> {:error, reason}
  end
end
```

### LiveView module

The product browser is the primary spindle. The checkout spindle is forked
when a product is selected — the `handle_yield/3` callback receives
`{:buy, product}` and forks it:

```elixir
defmodule MyApp.StoreLive do
  use MyAppWeb, :live_view
  use Skuld.PageMachine.AsyncPageMachine,
    tag: :products,
    on_yield: &handle_yield/3,
    on_complete: &handle_complete/3,
    on_error: &handle_error/3

  @impl true
  def mount(_params, _session, socket) do
    {:ok, runner} =
      AsyncPageMachine.run(
        MyApp.ProductBrowserSpindle.run(%{}),
        :products
      )

    {:ok,
     assign(socket,
       runner: runner,
       products: [],
       total: 0,
       page: 1
     )}
  end

  # Multi-spindle callbacks — dispatch by spindle key
  defp handle_yield(:products, {:results, products, total, page}, socket) do
    {:noreply, assign(socket, products: products, total: total, page: page)}
  end

  defp handle_yield(:products, {:buy, product}, socket) do
    {:noreply, assign(socket, step: :shipping)}
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

  # Product browser events — default to :products (the PMC tag)
  def_pipe_event "search", :runner, before: &start_spinner/1
  def_pipe_event "filter", :runner, before: &start_spinner/1
  def_pipe_event "page", :runner, before: &start_spinner/1
  def_pipe_event "buy", :runner

  # Checkout events — routed to :checkout spindle
  def_pipe_event "submit_shipping", :runner, into: :checkout, before: &start_spinner/1
  def_pipe_event "submit_payment", :runner, into: :checkout, before: &start_spinner/1

  @impl true
  def render(assigns) do
    ~H"""
    <div class="store-layout">
      <div class="product-browser">
        <.search_form myself={@myself} loading={@loading} />
        <.product_list products={@products} page={@page} total={@total} myself={@myself} />
      </div>
      <div class="checkout-panel">
        <%= case assigns[:step] do %>
          <% :shipping -> %>
            <.shipping_form loading={@loading} myself={@myself} />
          <% :payment -> %>
            <.payment_form loading={@loading} myself={@myself} />
          <% :done -> %>
            <.order_summary order={@order} />
          <% _ -> %>
            <p>Select a product to start checkout</p>
        <% end %>
      </div>
    </div>
    """
  end
end
```

Note: `FiberPool.Server.resume/4` with `fork: true` adds a new spindle to
the running server without replacing an existing one. The server routes
subsequent `:checkout` events to the forked spindle.

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
    assert %Coroutine.ExternalSuspended{value: :browsing} = fiber
  end

    test "buy event triggers checkout fork and yields product", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    fiber = Coroutine.run(fiber, {:buy, %Product{name: "Phone"}})
    # The buy yield surfaces for UI update; checkout spindle runs internally
    assert %Coroutine.ExternalSuspended{value: {:buy, %Product{name: "Phone"}}} = fiber
  end
end
```

## How the spindles collaborate

Each spindle is an independent coroutine. The product spindle loops: search,
yield results, wait for events (filters or buy). The checkout spindle runs
once per purchase: collect inputs, place order, exit. Both run concurrently
in the same FiberPool.Server process — cooperatively scheduled, no locking.

When the user clicks "buy, " the product spindle receives the event via
`Yield.yield`, forks a checkout spindle with `FiberPool.fiber`, yields a
UI update, and continues its search loop. The checkout spindle runs its
linear flow independently. If the user searches for more products
while the checkout form is still open, those events go to the product
spindle — the checkout spindle is unaffected.

## Dynamic forking

Spindles can fork other spindles from within their own computation using
`FiberPool.fiber/1`. The product spindle forks a checkout spindle when the
user clicks "buy" — the new spindle starts its linear flow while the
product spindle continues its search loop. Both run cooperatively in the
same server process.

This pattern keeps the LiveView layer simple: events pipe in via
`def_pipe_event`, computations spawn sub-computations as needed, and yields
bubble up to the UI. No back-and-forth between the LiveView and the server
for orchestration. The computation owns its lifecycle.

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
