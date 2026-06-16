# LiveView Integration

<!-- nav:header:start -->
[< AsyncCoroutine](../../../../docs/effects/async-coroutine.md) | [Index](../../../../README.md) | [Batch Loading >](batch-loading.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

LiveView pages are state machines — model, view, and update all living in
the same module. But these concerns are tangled: business logic, effect calls,
and socket manipulation mingle in `handle_event` and `handle_info` callbacks.
It's the equivalent of putting reducer logic, API calls, and DOM updates in a
single function.

PageMachine separates these concerns, Elixir-style. Like Elm, Redux,
or re-frame, it enforces a Model-View-Update architecture. But instead of pure
reducers, PageMachine uses coroutines: each coroutine is a state machine
computation that reads like normal code, but can *suspend* mid-execution,
*notify* the view without pausing, and resume where it left off.

A PageMachine runs one or more concurrent **spindles** — named coroutine
fibers, each an independent state machine computation with its own event
stream and its own yields and notifications to the LiveView.
A simple page might have just one spindle. A more complex multi-spindle
page can run a product browser *and* a checkout form, a chat panel *and*
a document editor — each region its own computation, its own testable
module. The LiveView routes events to the right spindle and forwards
yields from each to the right UI region.

## Why extract page state machines

LiveView modules mix three concerns: state transitions, business logic,
and DOM updates. When `handle_event` calls APIs, manipulates assigns,
and pushes UI state all in one function, the result is hard to test,
change, and reason about.

Extracting the state machine into a pure module — one that receives
events and returns new state, with no LiveView dependency — separates
these concerns. The spindle handles state and effects; the LiveView
bridges events and renders. This has two big payoffs:

- **Fast, deterministic tests** — test the page logic with plain
  `assert`. No process, LiveViewTest, or DOM. Even with DoubleDown
  replacing the database sandbox (often a 250× speedup for tests whose
  main bottleneck was Ecto sandbox DB I/O), the LiveView process itself
  sets a floor on test time. Pure state transitions have no such floor.
- **Decomplected code** — the spindle knows nothing about LiveView.
  It doesn't import `Phoenix.LiveView`, touch sockets, or manipulate
  assigns. Adding a UI region means adding a spindle, not threading
  more conditional logic through a monolithic `handle_event`.

## Pattern

1. Define a typed protocol with `use Skuld.PageMachine.Contract` and `defspindle` blocks
2. Write each page region as an effectful computation using the protocol's yield functions
3. Test each in isolation with `Coroutine` — deterministic, no processes
4. Wrap the page in a thin LiveView module via `use Skuld.PageMachine, protocol: ...` with `/3` callbacks
5. Computations fork sub-computations with `Spindle.fork`; yields update the UI

## Example: single-spindle product browser

A product search page — one spindle, one event loop. The user types a
query, the spindle fetches results, sends them to the LiveView, then
waits for the next event.

### Protocol

The protocol is the single source of truth for the spindle ↔ LiveView
contract. `defspindle` opens a spindle block; inside, `defevent` declares
events the LiveView can send to this spindle, `defyield` declares
blocking yields, and `defnotify` declares fire-and-forget notifications.

`defevent` takes an event name, an explicit struct name, and typed
params. It generates a struct module under the spindle (e.g.
`Search.SearchEvent`) and tells PageMachine to wrap incoming params
into that struct before resuming the spindle.

`defyield` and `defnotify` use function-head syntax — `defyield browsing`
generates `Search.Yield.browsing()` which pauses the spindle. `defnotify
results(products: [...], total: integer())` generates `Search.Notify.results(...)`,
fire-and-forget — the spindle surfaces results and continues without pausing:

```elixir
defmodule MyApp.SearchProtocol do
  use Skuld.PageMachine.Contract

  defspindle Search do
    defevent "search", SearchEvent, params: [query: String.t()]
    defevent "filter", FilterEvent, params: [filters: map()]

    defyield browsing
    defnotify results(products: [Product.t()], total: integer())
  end
end
```

### Spindle
The spindle is the computation — a function that fetches data,
surfaces results via `Search.Notify.results(...)`, and suspends on
`Search.Yield.browsing()` to wait for the next event. It uses the
protocol's generated functions and pattern-matches on the protocol's
generated structs (`%Search.SearchEvent{}`, `%Search.FilterEvent{}`):

```elixir
defmodule MyApp.SearchSpindle do
  use Skuld.Syntax

  alias MyApp.SearchProtocol.Search

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
    end
  end
end
```

### LiveView

```elixir
defmodule MyApp.SearchLive do
  use MyAppWeb, :live_view
  use Skuld.PageMachine,
    protocol: MyApp.SearchProtocol,
    on_yield: &handle_yield/3,
    on_complete: &handle_complete/3,
    on_error: &handle_error/3

  alias MyApp.SearchProtocol.Search

  @impl true
  def mount(_params, _session, socket) do
    socket =
      PageMachine.run(socket, Search => MyApp.SearchSpindle.run(%{}))
      |> assign(products: [], total: 0)

    {:ok, socket}
  end

  def handle_yield(_spindle, %Search.Notify.Results{products: products, total: total}, socket) do
    {:noreply, assign(socket, products: products, total: total)}
  end

  def handle_yield(_spindle, %Search.Yield.Browsing{}, socket), do: {:noreply, socket}

  def handle_complete(_spindle, {:error, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Search failed: #{inspect(reason)}")}
  end

  def handle_error(_spindle, reason, socket) do
    {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.search_form myself={@myself} />
      <.product_list products={@products} total={@total} myself={@myself} />
    </div>
    """
  end
end
```

A few things to note:

- **`/3` callbacks from the start** — the spindle module atom is the
  first argument. With a single spindle it's unused (`_spindle`), but
  using `/3` from the beginning means no refactoring when you add a
  second spindle — just add another clause.
- **`defevent` + struct name** — `defevent "search", SearchEvent, params: [...]`
  generates `Search.SearchEvent`. The auto-generated `handle_event` wraps
  the incoming params into the struct before resuming the spindle. This is
  why the `case event` in the spindle pattern-matches on `%Search.SearchEvent{}`.
- **`defyield` generates both a struct and a function** — `defyield browsing`
  produces `%Search.Yield.Browsing{}` and `Search.Yield.browsing()`.
  `defnotify results(...)` produces `%Search.Notify.Results{}` and
  `Search.Notify.results(products: ..., total: ...)` — same pattern, but
  `defnotify` is fire-and-forget: the spindle doesn't pause.

### Test

```elixir
  test "search yields results", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    assert %Coroutine.ExternalSuspended{value: %Search.Notify.Results{}} = fiber
  end

  test "filter event triggers new search", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    fiber = Coroutine.run(fiber, %Search.FilterEvent{filters: %{category: "books"}})
    assert %Coroutine.ExternalSuspended{value: %Search.Notify.Results{}} = fiber
  end
```

## Adding a second spindle: checkout

When you need an independent region with its own event loop — say a
checkout form alongside the product browser — add a second spindle.
The protocol gains a `Checkout` block, the LiveView switches to `/3`
callbacks, and the product spindle forks the checkout spindle on demand.

### Boundary contracts

```elixir
defmodule MyApp.ProductCatalog do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback search(filters :: map()) ::
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

### Protocol

The protocol extends to include `Checkout` alongside `Search`. The
`Checkout` spindle declares events for form submissions — when the
user fills the shipping and payment forms, the LiveView routes those
events back to the checkout spindle as typed structs:

```elixir
defmodule MyApp.StoreProtocol do
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

### Spindle computations

The search spindle is extended with a `%Search.BuyEvent{}` branch that
forks the checkout spindle and continues its own loop:

```elixir
defmodule MyApp.SearchSpindle do
  use Skuld.Syntax

  alias MyApp.StoreProtocol.{Search, Checkout}

  defcomp run(initial_filters) do
    search_loop(initial_filters)
  end

  defcomp search_loop(filters) do
    {:ok, products, total} <- MyApp.ProductCatalog.search(filters)
    _ <- Search.Notify.results(products: products, total: total)
    event <- Search.Yield.browsing()

    case event do
      %Search.BuyEvent{product: product} ->
        _handle <- Spindle.fork(Checkout, MyApp.CheckoutSpindle.run(product))
        search_loop(filters)

      %Search.FilterEvent{filters: filters} ->
        search_loop(filters)

      %Search.SearchEvent{query: query} ->
        search_loop(%{query: query})
    end
  end
end
```

The checkout spindle is forked with the selected product. It reserves
inventory, then yields `%Checkout.Yield.Shipping{}` and `%Checkout.Yield.Payment{}`
to drive a step-by-step form in the LiveView:

```elixir
defmodule MyApp.CheckoutSpindle do
  use Skuld.Syntax

  alias MyApp.StoreProtocol.Checkout

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

### LiveView

With two spindles, the LiveView switches to `/3` callbacks — the first
argument is the spindle module atom. The `:protocol` option auto-generates
`handle_event/3` from the protocol's `defevent` declarations:

```elixir
defmodule MyApp.StoreLive do
  use MyAppWeb, :live_view
  use Skuld.PageMachine,
    protocol: MyApp.StoreProtocol,
    on_yield: &handle_yield/3,
    on_complete: &handle_complete/3,
    on_error: &handle_error/3

  alias MyApp.{SearchSpindle, CheckoutSpindle}
  alias MyApp.StoreProtocol.{Search, Checkout}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      PageMachine.run(socket, Search => SearchSpindle.run(%{}))
      |> assign(products: [], total: 0)

    {:ok, socket}
  end

  def handle_yield(Search, %Search.Notify.Results{products: products, total: total}, socket) do
    {:noreply, assign(socket, products: products, total: total)}
  end

  def handle_yield(Search, %Search.Yield.Browsing{}, socket), do: {:noreply, socket}

  def handle_yield(Checkout, %Checkout.Yield.Shipping{}, socket) do
    socket = clear_spinner(socket)
    {:noreply, assign(socket, step: :shipping)}
  end

  def handle_yield(Checkout, %Checkout.Yield.Payment{}, socket) do
    socket = clear_spinner(socket)
    {:noreply, assign(socket, step: :payment)}
  end

  def handle_complete(Search, {:error, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Search failed: #{inspect(reason)}")}
  end

  def handle_complete(Checkout, {:ok, order}, socket) do
    socket = clear_spinner(socket)
    {:noreply, assign(socket, order: order, step: :done)}
  end

  def handle_error(Checkout, :sold_out, socket) do
    socket = clear_spinner(socket)
    {:noreply, put_flash(socket, :error, "Sorry, this item is no longer available")}
  end

  def handle_error(Checkout, reason, socket) do
    socket = clear_spinner(socket)
    {:noreply, put_flash(socket, :error, "Checkout failed: #{inspect(reason)}")}
  end

  defp start_spinner(socket), do: assign(socket, :loading, true)
  defp clear_spinner(socket), do: assign(socket, :loading, false)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="store-layout">
      <div class="product-browser">
        <.search_form myself={@myself} loading={@loading} />
        <.product_list products={@products} total={@total} myself={@myself} />
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

The key differences from the single-spindle version:

- **Additional clauses** — `handle_yield(Search, ...)` and
  `handle_yield(Checkout, ...)` dispatch by spindle module atom.
  The single-spindle used `_spindle`; here each clause names its spindle.
- **`Spindle.fork`** — the search spindle forks a checkout spindle
  rather than handling the buy event itself. The fork returns a
  `Handle` (ignored with `_handle`); the parent continues running.
  Completion and errors from the child are delivered via the LiveView.
- **`mount` starts only the primary spindle** — the checkout spindle
  doesn't exist until a `BuyEvent` arrives.

## Testing in isolation

Each spindle is tested independently with `Coroutine` — deterministic, no
processes, no stubs. Here's the search spindle from the single-spindle example:

```elixir
defmodule MyApp.SearchSpindleTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp.Env
  alias Skuld.Coroutine
  alias Skuld.Effects.Yield
  alias MyApp.SearchProtocol.Search

  setup do
    comp =
      MyApp.SearchSpindle.run(%{category: "electronics"})
      |> Port.with_handler(%{
        MyApp.ProductCatalog => fn _, :search, [%{category: "electronics"}] ->
          {:ok, [%Product{name: "Phone"}], 1}
        end
      })
      |> Yield.with_handler()

    {:ok, comp: comp}
  end

  test "first search yields results to the LiveView", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    assert %Coroutine.ExternalSuspended{value: %Search.Notify.Results{}} = fiber
  end

  test "filter event triggers new search and new results", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    fiber = Coroutine.run(fiber, %Search.FilterEvent{filters: %{category: "books"}})
    assert %Coroutine.ExternalSuspended{value: %Search.Notify.Results{}} = fiber
  end
end
```

These tests run in microseconds. There's no need for a LiveView process —
just pure state transitions.

## Why this works

Each spindle knows nothing about LiveView. It doesn't import
`Phoenix.LiveView`. It doesn't touch sockets, assigns, or DOM. It's a
pure function: `(state, event) -> new_state`. `Yield` marks the points
where the machine pauses for external input; `if` and `case` branch the flow.

This means:

- **Tests are fast**: no LiveView process, no DOM rendering.
- **Tests are deterministic**: same input → same path, every time.
- **Tests are property-testable**: generate inputs, assert paths.
- **The LiveView module is thin**: it only bridges events and renders
  based on the current step.

## Comparison to Elm / Redux / MVU

This architecture is an Elixir-based answer to the Model-View-Update
pattern that Elm enforces and Redux patterns towards:

| Concept      | Elm/Redux/re-frame       | PageMachine                       |
|--------------|--------------------------|-----------------------------------|
| Model        | Store / app-db           | Scoped effects + fiber            |
| Update       | Reducer / event handler  | Computation (`defcomp`)           |
| View         | Pure render              | `render(assigns)`                 |
| Event        | Action / dispatch        | `handle_event` / protocol `defspindle` `defevent` |
| State update | `:db` effect             | `Yield.yield(tag)`                |

In Elm and Redux, the reducer is a pure `(state, event) -> state` function —
it must return the new state immediately, without blocking.

PageMachine lifts this constraint with spindles — named coroutines that can
*suspend* mid-execution, surface state to the view via `Yield.yield`, and
resume where they left off when the next event arrives. Multiple spindles run
concurrently in the same server process: a product search doesn't block
checkout form submission, and UI regions update independently because each
yield carries the spindle key.

In re-frame terms, `Yield.yield(tag)` is analogous to returning a `:db`
effect: it updates the store (assigns), making new state visible to the
view's data subscriptions. The `/3` callback signature maps naturally to
re-frame's event handler receiving the event name as the first argument.

In standard LiveView, business logic, effect calls, and socket manipulation
mingle in `handle_event` / `handle_info` callbacks — the equivalent of putting
reducer logic, API calls, and DOM updates in a single function. PageMachine
separates them: the computation is the update function, the LiveView is the
view bridge. Effects are inline (`MyApp.ProductCatalog.search(filters, page)`
is a typed function call, not a dispatched action intercepted by middleware),
keeping the types visible and the flow linear.

## How the spindles collaborate

When the user clicks "buy," the product spindle receives the event, forks
a checkout spindle via `Spindle.fork`, and continues its search loop.
The checkout spindle runs its linear flow independently. If the user
searches while the checkout form is still open, those events go to the
product spindle — the checkout spindle is unaffected.

## Private and shared state

Each spindle carries its own private state through ordinary function
arguments — `search_loop(filters)` passes the current filters recursively,
no global store required. For shared state between spindles, use the
standard `Skuld.Effects.State` effect:

```elixir
defcomp search_loop(filters) do
  count <- State.get(:search_count)
  _ <- State.put(:search_count, count + 1)
  ...
end
```

Multiple spindles can read and write the same `State` tag within the
same PageMachine process. Any Skuld effect (`Writer`, `Reader`, etc.)
works the same way — each spindle is just a computation running inside
the FiberPool handler stack.

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
the FiberPool.Server process, which cancels all registered fibers.

## Operation reference

| Operation                              | Purpose                             |
|----------------------------------------|-------------------------------------|
| `PageMachine.run/1,2`                  | Start page machine with spindle keys|
| `PageMachine.resume/3`                 | Resume a spindle with a value       |
| `PageMachine.cancel/1`                 | Cancel page machine and spindles    |
| `Spindle.fork/2`                       | Fork a spindle from a computation   |
| `use Skuld.PageMachine, protocol: ...` | Typed protocol with auto-generated events and compile-time validation |
| `use Skuld.PageMachine.Contract`       | Define a typed event/yield protocol |

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

[< AsyncCoroutine](../../../../docs/effects/async-coroutine.md) | [Index](../../../../README.md) | [Batch Loading >](batch-loading.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
