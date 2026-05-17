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

## The effect advantage

Effectful computations condense domain logic to its essence. Handlers
provide context — production vs test, concurrency, batching — without
touching the computation. Effects are first-class data: inspect them,
serialise them, replay them. The same mechanism that enables suspension
and resumption in the first example also enables automatic N+1 batching
in the second and durable computation in the third.

### Suspension & resumption

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

[Full LiveView integration recipe →](docs/recipes/liveview.md)

### Composability

Effects compose with zero ceremony. This query function reads like
straightforward sequential code, but when it runs, concurrency
happens at two levels: within the `defquery` block (`fetch_user`
and `fetch_orders` run together via dependency analysis), and
across all streamed invocations — `Brook.map` runs 4 transforms
concurrently, and `FiberPool` batches their `deffetch` calls into
single round-trips:

```elixir
defquery build_account_summary(user_id, month) do
  user <- AccountQueries.fetch_user(user_id)
  orders <- AccountQueries.fetch_orders(user_id, month)
  details <- Query.map(Enum.map(orders, & &1.id), &AccountQueries.fetch_order_details/1)
  build_account_summary(user, orders, details)
end

# Feed a stream of users through — 4 concurrent transforms, all deffetch
# calls batched together by FiberPool
user_ids
|> Brook.from_enum()
|> Brook.map(&build_account_summary(&1, "2026-01"), concurrency: 4)
|> Brook.to_list()
|> Skuld.Query.with_executor(AccountQueries, AccountExecutor)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

`build_account_summary` knows nothing about batch sizes, concurrency limits,
database round-trips, or the other account summaries which also need to be
built - it's pure domain logic. Everything else is handler
wiring — swappable, testable, composable.

[Full batch loading recipe →](docs/recipes/batch-loading.md)

### Durability

Effects are data you can persist. Pause a multi-step wizard, save
its entire execution history as JSON, and resume it later — after
a restart, on a different machine:

```elixir
wizard =
  comp do
    name <- Yield.yield(:get_name)
    email <- Yield.yield(:get_email)
    {:ok, %{name: name, email: email}}
  end

sc =
  SerializableCoroutine.new(wizard, fn comp ->
    comp |> Yield.with_handler() |> Throw.with_handler()
  end)

# Run until suspension, serialize the effect log
suspended = SerializableCoroutine.run(sc)
json = SerializableCoroutine.serialize(SerializableCoroutine.get_log(suspended))
# => EffectLogEntry{data: :get_name, value: nil, state: :started}

# Later — cold resume from JSON, no manual deserialisation needed
suspended2 = SerializableCoroutine.run(json, sc, "Alice")
# => EffectLogEntry{data: :get_name, value: "Alice", state: :executed}
# => EffectLogEntry{data: :get_email, value: nil, state: :started}
```

Every effect invocation — yields, state changes, writer events —
is captured in the log. `run` replays recorded effects and resumes
at the suspension point. The same mechanism that enables batching
in the composability example enables durability here.

[Full durable computation recipe →](docs/recipes/durable-computation.md)

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
