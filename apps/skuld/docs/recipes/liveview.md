# LiveView Integration

<!-- nav:header:start -->
[< AsyncCoroutine](../../../../docs/effects/async-coroutine.md) | [Index](../../../../README.md) | [Batch Loading >](batch-loading.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

PageMachine removes the state machines from a LiveView, and moves them into
Spindles — each Spindle is a single coroutine-based state machine which
manages state and effects for a thread of control in a page.

Let's start with a simple Spindle — a checkout flow:

```elixir
defmodule MyApp.CheckoutSpindle do
  use Skuld.Syntax
  alias MyApp.StoreContract.Checkout

  defcomp run(product) do
    {:ok, _} <- MyApp.Inventory.reserve(%{product: product})
    %Checkout.ShippingEvent{shipping: shipping} <- Checkout.Yield.shipping()
    %Checkout.PaymentEvent{payment: payment} <- Checkout.Yield.payment()
    {:ok, order} <- MyApp.Orders.place(%{product: product}, shipping, payment)
    {:ok, order}
  else
    {:error, :sold_out} -> {:error, :sold_out}
    {:error, reason} -> {:error, reason}
  end
end
```

That's the entire checkout state machine. Read it top to bottom:

1. Reserve inventory (an effect — calls the backend)
2. Yield to the LiveView to collect shipping info (the spindle **suspends** here, the LiveView renders a shipping form, the user submits, the spindle resumes with the event)
3. Yield again for payment info (same pattern)
4. Place the order (another effect)
5. Error handling at the bottom — `sold_out` or any other failure

There's no `handle_event`, `handle_info`, or socket assigns here. The spindle
is a pure computation — it doesn't know the LiveView exists.
Each `<-` is either an effect call (to the backend) or a yield
(to the LiveView). The coroutine suspends at each yield and resumes
when the LiveView sends the next event.

## Driving a LiveView

To connect a Spindle to a LiveView we need a PageMachine Contract —
the Contract defines the events that the LiveView can send to the
PageMachine, and the yields that the PageMachine's Spindles can return
to the LiveView:

```elixir
defmodule MyApp.StoreContract do
  use Skuld.PageMachine.Contract

  defspindle Checkout do
    defevent "submit_shipping", ShippingEvent, params: [shipping: map()]
    defevent "submit_payment", PaymentEvent, params: [payment: map()]

    defyield shipping
    defyield payment
  end
end
```

`defevent` declares an event the LiveView can send — it generates a
typed struct (`Checkout.ShippingEvent`, `Checkout.PaymentEvent`) and
auto-generates the `handle_event` clause in the LiveView.

`defyield` declares a suspension point — it generates a function
(`Checkout.Yield.shipping()`) that pauses the Spindle and sends a
struct (`%Checkout.Yield.Shipping{}`) to the LiveView.

## The LiveView is reduced

The LiveView uses the contract, to auto-generate the `handle_event`
and `handle_info` clauses required to wire up the PageMachine's Spindles:

```elixir
defmodule MyApp.CheckoutLive do
  use MyAppWeb, :live_view
  use Skuld.PageMachine,
    contract: MyApp.StoreContract,
    on_yield: &handle_yield/3,
    on_complete: &handle_complete/3,
    on_error: &handle_error/3

  alias MyApp.StoreContract.Checkout

  @impl true
  def mount(%{"product_id" => product_id}, _session, socket) do
    product = MyApp.Products.get!(product_id)

    socket =
      PageMachine.run(socket, Checkout => MyApp.CheckoutSpindle.run(product))
      |> assign(step: :loading, product: product)

    {:ok, socket}
  end

  defp handle_yield(Checkout, %Checkout.Yield.Shipping{}, socket) do
    {:noreply, assign(socket, step: :shipping)}
  end

  defp handle_yield(Checkout, %Checkout.Yield.Payment{}, socket) do
    {:noreply, assign(socket, step: :payment)}
  end

  defp handle_complete(Checkout, {:ok, order}, socket) do
    {:noreply, assign(socket, step: :done, order: order)}
  end

  defp handle_error(Checkout, reason, socket) do
    {:noreply, put_flash(socket, :error, "Checkout failed: #{inspect(reason)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= case @step do %>
        <% :loading -> %> <p>Reserving inventory…</p>
        <% :shipping -> %> <.shipping_form />
        <% :payment -> %> <.payment_form />
        <% :done -> %> <.order_summary order={@order} />
      <% end %>
    </div>
    """
  end
end
```

The LiveView has no business logic. It receives yield structs, updates
assigns, and renders. The contract's auto-generated `handle_event`
clauses route form submissions (`"submit_shipping"`, `"submit_payment"`)
back to the Spindle as typed event structs — no manual wiring required.

## Another Spindle

If you've been paying attention you might have noticed that the Checkout
Spindle pauses for a response at its yield points — this makes the logic
compact and easy to read, but it's not appropriate for all situations.
Let's add another Spindle to the PageMachine, to browse products:

```elixir
defmodule MyApp.SearchSpindle do
  use Skuld.Syntax
  alias MyApp.StoreContract.Search

  defcomp run(initial_filters) do
    search_loop(initial_filters)
  end

  defcomp search_loop(filters) do
    {:ok, products, total} <- MyApp.ProductCatalog.search(filters)
    _ <- Search.Notify.results(products: products, total: total)
    event <- Search.Yield.browsing()

    case event do
      %Search.SearchEvent{query: query} ->
        search_loop(%{query: query})

      %Search.FilterEvent{filters: filters} ->
        search_loop(filters)

      %Search.BuyEvent{product: product} ->
        _handle <- Spindle.fork(Checkout, MyApp.CheckoutSpindle.run(product))
        search_loop(filters)
    end
  end
end
```

This Spindle introduces two new concepts:

- **`Notify`** — `Search.Notify.results(...)` sends data to the LiveView
  *without pausing*. The Spindle fires off the results and immediately
  continues to `Search.Yield.browsing()` where it waits for the next
  event. Compare with Checkout's `Yield`, which pauses until the
  LiveView responds.
- **`Spindle.fork`** — when the user clicks "buy", the Search Spindle
  forks a Checkout Spindle and continues its own loop. The two Spindles
  now run concurrently in the same PageMachine — searching doesn't
  block checkout, and vice versa.

The contract gains a `Search` block for the new Spindle:

```elixir
defmodule MyApp.StoreContract do
  use Skuld.PageMachine.Contract

  defspindle Search do
    defevent "search", SearchEvent, params: [query: String.t()]
    defevent "filter", FilterEvent, params: [filters: map()]
    defevent "buy", BuyEvent, params: [product: Product.t()]

    defyield browsing
    defnotify results(products: [Product.t()], total: integer())
  end

  defspindle Checkout do
    defevent "submit_shipping", ShippingEvent, params: [shipping: map()]
    defevent "submit_payment", PaymentEvent, params: [payment: map()]

    defyield shipping
    defyield payment
  end
end
```

The LiveView has to deal with more data from the Search Spindle, but
all the `handle_event` and `handle_info` clauses are still auto-generated
from the expanded Contract:

```elixir
defmodule MyApp.StoreLive do
  use MyAppWeb, :live_view
  use Skuld.PageMachine,
    contract: MyApp.StoreContract,
    on_yield: &handle_yield/3,
    on_complete: &handle_complete/3,
    on_error: &handle_error/3

  alias MyApp.StoreContract.{Search, Checkout}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      PageMachine.run(socket, Search => MyApp.SearchSpindle.run(%{}))
      |> assign(products: [], total: 0)

    {:ok, socket}
  end

  defp handle_yield(Search, %Search.Notify.Results{products: products, total: total}, socket) do
    {:noreply, assign(socket, products: products, total: total)}
  end

  defp handle_yield(Search, %Search.Yield.Browsing{}, socket), do: {:noreply, socket}

  defp handle_yield(Checkout, %Checkout.Yield.Shipping{}, socket) do
    {:noreply, assign(socket, step: :shipping)}
  end

  defp handle_yield(Checkout, %Checkout.Yield.Payment{}, socket) do
    {:noreply, assign(socket, step: :payment)}
  end

  defp handle_complete(Checkout, {:ok, order}, socket) do
    {:noreply, assign(socket, step: :done, order: order)}
  end

  defp handle_error(_spindle, reason, socket) do
    {:noreply, put_flash(socket, :error, inspect(reason))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="store-layout">
      <div class="product-browser">
        <.search_form />
        <.product_list products={@products} total={@total} />
      </div>
      <%= if assigns[:step] do %>
        <div class="checkout-panel">
          <%= case @step do %>
            <% :shipping -> %> <.shipping_form />
            <% :payment -> %> <.payment_form />
            <% :done -> %> <.order_summary order={@order} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
```

The first argument to each callback is the Spindle module — `Search` or
`Checkout` — so the LiveView dispatches by pattern match. Only the Search
Spindle is started in `mount`; the Checkout Spindle appears when
`Spindle.fork` fires from the Search Spindle's `BuyEvent` handler.

## Rounding up

That covers the core of the PageMachine concept: replace the implied
state machines inside every LiveView with explicit coroutine-based state
machines outside the LiveView. The LiveView becomes just a view, and the
coroutine-based state machines can be tested without any LiveView
machinery — so the tests run fast enough for property-based testing!

```elixir
test "checkout flow: reserve → shipping → payment → order" do
  fiber =
    MyApp.CheckoutSpindle.run(product)
    |> Port.with_handler(test_handlers)
    |> Yield.with_handler()
    |> Coroutine.new(Env.new())
    |> Coroutine.run()

  assert %ExternalSuspended{value: %Checkout.Yield.Shipping{}} = fiber

  fiber = Coroutine.run(fiber, %Checkout.ShippingEvent{shipping: shipping})
  assert %ExternalSuspended{value: %Checkout.Yield.Payment{}} = fiber

  fiber = Coroutine.run(fiber, %Checkout.PaymentEvent{payment: payment})
  assert %Completed{result: {:ok, %Order{}}} = fiber
end
```

No LiveView, process, or DOM — just state transitions in microseconds.

## Comparison to Elm / Redux / MVU

This architecture is an Elixir-based answer to the Model-View-Update
pattern that Elm enforces and Redux aspires to:

| Concept      | Elm/Redux/re-frame      | PageMachine                                       |
|--------------|-------------------------|---------------------------------------------------|
| Model        | Store / app-db          | Scoped effects + fiber                            |
| Update       | Reducer / event handler | Computation (`defcomp`)                           |
| View         | Pure render             | `render(assigns)`                                 |
| Event        | Action / dispatch       | `handle_event` / contract `defspindle` `defevent` |
| State update | `:db` effect            | `Yield.yield(tag)`                                |

In Elm and Redux, the reducer is a pure `(state, event) -> state` function —
it must return the new state immediately, without blocking. PageMachine
lifts this constraint: Spindles are coroutines that can suspend mid-execution,
call effects, and resume where they left off. Multiple Spindles run
concurrently in the same server process, updating the LiveView independently.

## Private and shared state

Each spindle carries its own private state through ordinary function
arguments — `search_loop(filters)` passes the current filters recursively,
so no global store is required.

If you need shared state between spindles, you can use `Skuld.Effects.Cell`
— a single-writer, multi-reader mutable cell. The first Spindle to write to a
tag claims ownership; any Spindle can read. This prevents accidental
cross-spindle writes while allowing safe concurrent reads:

```elixir
defcomp search_loop(filters) do
  {:ok, products, total} <- MyApp.ProductCatalog.search(filters)
  _ <- Cell.put(:search_results, products)
  ...
end
```

Other spindles read the current value directly:

```elixir
defcomp recommendation_loop() do
  products <- Cell.get(:search_results)
  recommendations <- MyApp.Recommendations.for(products)
  ...
end
```

### Watching for changes

When a Spindle needs to react to another Spindle's state change,
`Cell.watch(tag)` returns a capacity-1 Channel that delivers the value
when it's written. If the Cell already has a value, the channel
contains it immediately (closed). If not, the channel is empty until
`Cell.put` writes to the tag — at which point all watcher channels
receive the value and close.

This composes naturally with `FiberPool.await_any` for multi-source await —
"wake me when state changes, OR an event arrives, OR a network response
comes back." Here a dashboard Spindle watches for search results while
simultaneously waiting for its own events:

```elixir
defcomp dashboard_loop() do
  watch_fiber <- FiberPool.fiber(comp do
    ch <- Cell.watch(:search_results)
    Channel.take(ch)
  end)

  event_fiber <- FiberPool.fiber(Yield.yield(:dashboard))

  {_handle, result} <- FiberPool.await_any([watch_fiber, event_fiber])

  case result do
    {:ok, {:ok, products}} ->
      _ <- Dashboard.Notify.results_updated(products: products)
      dashboard_loop()

    {:ok, %Dashboard.RefreshEvent{}} ->
      dashboard_loop()
  end
end
```

The watcher channel never blocks the writer — capacity 1 with
immediate close means `Cell.put` always succeeds without suspension,
regardless of how many watchers are registered.

## Cancellation and cleanup

Cancel on mount to prevent duplicate runners:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    socket.assigns[:pm] && PageMachine.cancel(socket.assigns.pm)
  end
  ...
end
```

Cancellation cascades to all spindles — `PageMachine.cancel/1` exits
the FiberPool.Server process, which cancels all registered Spindles.

## Operation reference

| Operation                              | Purpose                             |
|----------------------------------------|-------------------------------------|
| `PageMachine.run/1,2`                  | Start page machine with spindle keys|
| `PageMachine.resume/3`                 | Resume a spindle with a value       |
| `PageMachine.cancel/1`                 | Cancel page machine and spindles    |
| `Spindle.fork/2`                       | Fork a spindle from a computation   |
| `use Skuld.PageMachine, contract: ...` | Typed contract with auto-generated events and compile-time validation |
| `use Skuld.PageMachine.Contract`       | Define a typed event/yield contract |


<!-- nav:footer:start -->

---

[< AsyncCoroutine](../../../../docs/effects/async-coroutine.md) | [Index](../../../../README.md) | [Batch Loading >](batch-loading.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
