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
reducers that must return immediately, PageMachine uses coroutines: each
state machine is a sequential computation that can *suspend* mid-execution,
surface updates to the view, and resume where it left off.

A PageMachine runs one or more concurrent **spindles** — named coroutine
fibers, each an independent state machine with its own event stream and its
own yields to the LiveView. A single-spindle page is just a page machine with
one spindle. A multi-spindle page runs a product browser *and* a checkout form,
a chat panel *and* a document editor — each region its own computation, its
own testable module. The LiveView routes events to the right spindle and
forwards yields from each to the right UI region.

## Why extract page state machines

LiveView tests are slow. Even with DoubleDown replacing the database
sandbox (often a 250× speedup for tests whose main bottleneck was Ecto sandbox
DB I/O), the process mechanics dominate — mount, render,
socket assigns, DOM diffs. The test time floor is set by the LiveView
process itself.

But a LiveView page *is* a state machine. The Moore model maps directly:

| Moore concept | LiveView                         |
|---------------|----------------------------------|
| State         | `socket.assigns`                 |
| Transition    | `handle_event(event, _, socket)` |
| Output (UI)   | `render(socket.assigns)`         |

If you extract the state machine into a pure module — one that receives
events and returns new state, with no LiveView dependency — you can test
the page logic with plain `assert`. No process. No LiveViewTest. No DOM.

## Pattern

1. Write each page region as an effectful computation using `Yield`
2. Test each in isolation with `Coroutine` — deterministic, no processes
3. Wrap the page in a thin LiveView module via `use Skuld.PageMachine` with `/3` callbacks
4. Use `def_pipe_event` to forward LiveView events to the correct spindle
5. Computations fork sub-computations as needed; yields update the UI

The `:tag` option on `use` is optional — it defaults to
`Skuld.PageMachine.Default`. Pass an explicit tag only when a page hosts
multiple page machines. Every spindle key (in `handle_yield`, `:into`,
`Spindle.fork`, and `run/2`) is always explicit.

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
| `:products` | Forever loop: search products, select one to buy | `"search"`, `"filter"` events |
| `:checkout` | Forked on buy: collect shipping, payment, place order | `"submit_shipping"`, `"submit_payment"` events |

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

### Spindle computations

The product browser spindle runs forever — each search yields results, then
loops for the next event. When the user clicks "buy," it forks a checkout
spindle and continues its own loop:

```elixir
defmodule MyApp.ProductBrowserSpindle do
  use Skuld.Syntax

  alias Skuld.Effects.Yield

  defcomp run(initial_filters) do
    search_loop(initial_filters)
  end

  defcomp search_loop(filters) do
    {:ok, products, total} <- MyApp.ProductCatalog.search(filters)
    event <- Yield.yield(:browsing)

    case event do
      {:buy, product} ->
        _handle <- Spindle.fork(:checkout, MyApp.CheckoutSpindle.run(product))
        search_loop(filters)

      new_filters ->
        search_loop(new_filters)
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

Each computation reads like regular sequential code — there's no explicit
state enumeration, transition table, or event loop. This is possible
because Skuld's coroutines are a natural fit for implementing state
machines: each `Yield.yield` suspends at a well-defined point, and each
resume value picks up where it left off. The computation *is* the state
machine, and the program counter *is* the current state.
([Coroutines are a classic technique for implementing state
machines.](https://en.wikipedia.org/wiki/Coroutine#Common_uses))

### LiveView module

The product browser is the primary spindle — started at mount.
The checkout spindle is forked on demand. The `/3` callbacks route
each yield to the right UI region:

```elixir
defmodule MyApp.StoreLive do
  use MyAppWeb, :live_view
  use Skuld.PageMachine,
    on_yield: &handle_yield/3,
    on_complete: &handle_complete/3,
    on_error: &handle_error/3

  @impl true
  def mount(_params, _session, socket) do
    socket =
      PageMachine.run(socket,
        products: MyApp.ProductBrowserSpindle.run(%{})
      )
      |> assign(products: [], total: 0)

    {:ok, socket}
  end

  # Multi-spindle callbacks — dispatch by spindle key
  defp handle_yield(:products, {:results, products, total}, socket) do
    {:noreply, assign(socket, products: products, total: total)}
  end

  defp handle_yield(:checkout, step, socket) do
    socket = clear_spinner(socket)
    {:noreply, assign(socket, step: step)}
  end

  defp handle_complete(:products, {:error, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Product search failed: #{inspect(reason)}")}
  end

  defp handle_complete(:checkout, {:ok, order}, socket) do
    socket = clear_spinner(socket)
    {:noreply, assign(socket, order: order, step: :done)}
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
  def_pipe_event "search", into: :products, before: &start_spinner/1
  def_pipe_event "filter", into: :products, before: &start_spinner/1
  def_pipe_event "buy", into: :products

  # Checkout events — routed to :checkout spindle
  def_pipe_event "submit_shipping", into: :checkout, before: &start_spinner/1
  def_pipe_event "submit_payment", into: :checkout, before: &start_spinner/1

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

## Testing in isolation

Each spindle is tested independently with `Coroutine` — deterministic, no
processes, no stubs:

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
        MyApp.ProductCatalog => fn _, :search, [%{category: "electronics"}] ->
          {:ok, [%Product{name: "Phone"}], 1}
        end
      })
      |> Yield.with_handler()

    {:ok, comp: comp}
  end

  test "first search yields browsing state", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    assert %Coroutine.ExternalSuspended{value: :browsing} = fiber
  end

    test "buy event triggers checkout fork and continues search loop", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    fiber = Coroutine.run(fiber, {:buy, %Product{name: "Phone"}})
    assert %Coroutine.ExternalSuspended{value: :browsing} = fiber
  end

  test "filter change triggers new search", %{comp: comp} do
    fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
    fiber = Coroutine.run(fiber, %{category: "books"})
    assert %Coroutine.ExternalSuspended{value: :browsing} = fiber
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

This architecture is Elixir's answer to the Model-View-Update pattern that
Elm enforces and Redux patterns towards:

| Concept      | Elm/Redux/re-frame       | PageMachine                       |
|--------------|--------------------------|-----------------------------------|
| Model        | Store / app-db           | Scoped effects + fiber            |
| Update       | Reducer / event handler  | Computation (`defcomp`)           |
| View         | Pure render              | `render(assigns)`                 |
| Event        | Action / dispatch        | `handle_event` / `def_pipe_event` |
| State update | `:db` effect             | `Yield.yield(tag)`                |

In Elm and Redux, the reducer is a pure `(state, event) -> state` function —
it must return the new state immediately. PageMachine lifts this constraint
with coroutines: the update function can *suspend* mid-execution, surface state
to the view via `Yield.yield`, and resume where it left off when the next
event arrives.

With spindles, multiple update functions run concurrently — each spindle is
an independent coroutine that yields independently. A product search doesn't
block checkout form submission. The UI regions update independently because
each yield carries the spindle key.

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

Each spindle is an independent coroutine. The product spindle loops: search,
yield results, wait for events (filters or buy). The checkout spindle runs
once per purchase: collect inputs, place order, exit. Both run concurrently
in the same FiberPool.Server process — cooperatively scheduled, no locking.

When the user clicks "buy," the product spindle receives the event via
`Yield.yield`, forks a checkout spindle with `Spindle.fork`, yields a
UI update, and continues its search loop. The checkout spindle runs its
linear flow independently. If the user searches for more products
while the checkout form is still open, those events go to the product
spindle — the checkout spindle is unaffected.

## Dynamic forking

Spindles can fork other spindles from within their own computation using
`Spindle.fork/2`. The product spindle forks a checkout spindle when the
user clicks "buy" — the new spindle starts its linear flow while the
product spindle continues its search loop. Both run cooperatively in the
same server process.

This pattern keeps the LiveView layer simple: events pipe in via
`def_pipe_event`, computations spawn sub-computations as needed, and yields
bubble up to the UI. No back-and-forth between the LiveView and the server
for orchestration. The computation owns its lifecycle.

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
| `PageMachine.def_pipe_event/2,4`       | Generate `handle_event/3`           |
| `PageMachine.cancel/1`                 | Cancel page machine and spindles    |
| `Spindle.fork/2`                       | Fork a spindle from a computation   |

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
