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
loops for the next event. When the user clicks "buy," it yields the selected
product and loops back:

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
    # Fork a checkout spindle with the selected product
    FiberPool.Server.resume(socket.assigns.runner, :checkout,
      MyApp.CheckoutSpindle.run(product),
      fork: true
    )

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

  test "buy event yields the selected product", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    fiber = Coroutine.run(fiber, {:buy, %Product{name: "Phone"}})
    assert %Coroutine.ExternalSuspended{value: {:buy, %Product{name: "Phone"}}} = fiber
  end

  test "filter change triggers new search, buy after search yields product" do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    fiber = Coroutine.run(fiber, {:buy, %Product{name: "Phone"}})
    assert %Coroutine.ExternalSuspended{value: {:buy, %Product{name: "Phone"}}} = fiber
  end
end
```

## How the spindles collaborate

Each spindle is an independent coroutine. The product spindle loops: search,
yield results, wait for events (filters or buy). The checkout spindle runs
once per purchase: collect inputs, place order, exit. Both run concurrently
in the same FiberPool.Server process — cooperatively scheduled, no locking.

When the user clicks "buy," the product spindle yields `{:buy, product}`.
The LiveView's `handle_yield/3` callback catches it and forks a checkout
spindle. The checkout spindle runs its linear flow independently. If the
user searches for more products while the checkout form is still open,
those events go to the product spindle — the checkout spindle is
unaffected.

## Dynamic forking vs static registration

Spindles can be registered in two ways:

1. **Static**: Pass all spindle computations to `AsyncPageMachine.run/2` at
   mount time. All spindles start together.
2. **Dynamic**: Fork spindles on demand via `FiberPool.Server.resume/4` with
   `fork: true`. Useful when spindles are triggered by user actions — a
   "buy" click, a "view details" tap, a "start upload" drag-and-drop.

Dynamic forking keeps the initial page load light and avoids starting
computations the user may never trigger.

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
