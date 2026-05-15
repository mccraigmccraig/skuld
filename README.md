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

```elixir
defmodule Dashboard do
  use Skuld.Syntax

  alias Skuld.Query

  defcomp load(user_id) do
    query do
      user <- Users.get_user(user_id)
      posts <- Posts.recent_by(user.id)         # runs concurrently with ↓
      sub <- Billing.get_subscription(user.id)   # runs concurrently with ↑
      {:ok, %{user: user, posts: posts, subscription: sub}}
    end
  end
end
```

Even though `posts` and `sub` look sequential, the query system analyzes
dependencies — they're independent of each other (both depend on `user`,
not on each other) — and batches them into a single round-trip.

Run with production executors:

```elixir
Dashboard.load("user-123")
|> Skuld.Query.with_cached_executors([
  {Users, Users.EctoExecutor},
  {Posts, Posts.EctoExecutor},
  {Billing, Billing.HTTPExecutor}
])
|> FiberPool.with_handler()
|> Comp.run!()
```

Run with test executors — deterministic, no database, no HTTP:

```elixir
Dashboard.load("user-123")
|> Skuld.Query.with_cached_executors([
  {Users, Users.TestExecutor},
  {Posts, Posts.TestExecutor},
  {Billing, Billing.TestExecutor}
])
|> FiberPool.with_handler()
|> Comp.run!()
```

Same code. Production calls Ecto and HTTP; tests run against in-memory
maps. The batching, concurrency, and error handling are all effects —
swap handlers, not code.

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
