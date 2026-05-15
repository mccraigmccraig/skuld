# Skuld

<!-- nav:header:start -->
[Why Effects? >](docs/why.md)
<!-- nav:header:end -->

[![Test](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/skuld.svg)](https://hex.pm/packages/skuld)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/skuld/)

An effectful programming framework for Elixir.

```
                          Comp
                     (lazy computation,
                      evidence-passing,
                      scoped handlers)
                            │
      ┌─────────────────────┼───────────────────────────┐
      │                     │                           │
 //Foundational       //Coroutines &               //Boundaries
 //Effects            //Concurrency                     │
      │                     │                           │
      │                 Coroutine                ┌──────┼────┐
      │                     │                    │      │    │
 State, Reader,    ┌────────┼─────────┐          │      │  Port
 Writer, Throw,    │        │         │          │      │  Port.EffectfulFacade
 Bracket, Fresh,   │  Serializable-   │          │      │  Repo
 Random, FxList,   │   Coroutine      │          │      │
 Yield,            │                  │          │      │
 EffectLogger,  AsyncCoroutine     FiberPool     │  Adapter
 Parallel,                            │          │  Adapter.EffectfulContract
 AtomicState,                         ├─────────┐│
 Transaction,                         │         ││
 Command                              │         ││
                                 ┌────┴────┐    ││
                              Channel    Task   ││
                                 │              ││
                               Brook            ││
                                                ││
                                           Query.Contract
                                           QueryBlock
                                           (Haxl-like: auto-batches fetches
                                           via Coroutine fibers)
```

## The old problem

Between pure business logic and side-effecting infrastructure
sits the orchestration layer — "fetch the user, check permissions, load
their subscription, hit some APIs, compute a price, write an invoice."
This code encodes your most important business rules, but it's tangled with
databases, APIs, and randomness — making it hard to test, hard to
refactor, and often — impossible to property-test.

## Another way

Skuld lets you write orchestration code that *describes* side effects
without performing them — then handlers decide what those descriptions mean.
The exact same "effectful" code runs with side-effecting handlers in production
and pure in-memory handlers in tests — fully deterministic, fully pure, and
straightforwardly property-testable.

Because effects are first-class data, Skuld can do more — batch
independent queries automatically, serialise partially complete computations
for later resumption.

## Quick example

A multi-step checkout wizard. The computation *pauses* at each step,
waiting for external input — then resumes with full effect context
preserved:

```elixir
defmodule Checkout do
  use Skuld.Syntax

  alias Skuld.Effects.Yield

  defcomp run do
    cart <- Yield.yield(:get_cart)
    {:ok, inventory} <- Inventory.check_stock(cart.items)
    payment <- Yield.yield(:get_payment)
    {:ok, order} <- Orders.place(cart, payment)
    _ <- Emailer.send_confirmation(order)
    {:ok, order}
  end
end
```

Run it from a LiveView with `AsyncCoroutine`:

```elixir
# mount
{:ok, runner} = AsyncCoroutine.run(Checkout.run(), tag: :checkout)

# handle_info — the wizard pauses at each yield
def handle_info({AsyncCoroutine, :checkout, %ExternalSuspend{value: :get_cart}}, socket) do
  cart = ShoppingCart.get_cart(socket.assigns.user)
  AsyncCoroutine.run(socket.assigns.runner, cart)   # resume with cart
  {:noreply, socket}
end

def handle_info({AsyncCoroutine, :checkout, %ExternalSuspend{value: :get_payment}}, socket) do
  payment = socket.assigns.payment_form |> to_payment_method()
  AsyncCoroutine.run(socket.assigns.runner, payment) # resume with payment
  {:noreply, socket}
end

def handle_info({AsyncCoroutine, :checkout, {:ok, order}}, socket) do
  {:noreply, assign(socket, order: order, step: :done)}
end
```

Test it — drive the whole wizard in a few lines:

```elixir
comp =
  Checkout.run()
  |> Port.with_handler(%{Inventory => Inventory.Test, Orders => Orders.Test})
  |> Port.with_test_handler(%{Port.key(Emailer, :send_confirmation, [_]) => :ok})
  |> Yield.with_handler()
  |> Throw.with_handler()

fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()    # pauses at :get_cart
fiber = Coroutine.run(fiber, %{items: [...]})                  # pauses at :get_payment
%Coroutine.Completed{result: {:ok, order}} =
  Coroutine.run(fiber, %{card: "4242..."})                     # completes
```

Same code. Production pauses at each step for user input. Tests drive
the entire wizard in a single function — deterministic, no processes,
no stubs.

## Installation

```elixir
def deps do
  [
    {:skuld, "~> 0.27"}
  ]
end
```

## Where next?

| If you want to... | Read |
|---|---|
| Understand the problem effects solve | [Why Effects?](docs/why.md) |
| See how effects and handlers work | [How It Works](docs/what.md) |
| Write your first computation | [Getting Started](docs/getting-started.md) |
| State, Reader, Writer, Throw, Fresh, Random | [Foundational Effects](docs/effects/state-reader-writer.md) |
| Yield, Coroutines, FiberPool, Channels, Async | [Coroutines & Concurrency](docs/effects/yield.md) |
| Port, Repo, Hexagonal Architecture | [Boundaries](docs/effects/port.md) |
| Eliminate N+1 queries | [Query System](docs/effects/query.md) |
| Handler-swapping for deterministic testing | [Testing](docs/testing.md) |
| Full effect and API reference | [Reference](docs/reference.md) |

## License

MIT License — see [LICENSE](LICENSE) for details.

<!-- nav:footer:start -->

---

[Why Effects? >](docs/why.md)
<!-- nav:footer:end -->
