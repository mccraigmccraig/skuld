# Skuld

<!-- nav:header:start -->
[Getting Started >](docs/getting-started.md)
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
      ┌─────────────────────┼─────────────────────────────┐
      │                     │                             │
 //Foundational       //Coroutines &                 //Boundaries
 //Effects            //Concurrency                       │
      │                     │                             │
      │                 Coroutine                ┌────────┼────────┐
      │                     │                    │        │        │
 State, Reader,        ┌────┴──────┐             │        │       Port
 Writer, Throw,        │           │             │        │        │
 Bracket, Fresh,  Serializable-    │             │        │    Port.Facade
 Random, FxList,   Coroutine       │             │        │    Repo
 Yield,                            │             │        │
 EffectLogger,                     │             │    Adapter
 Parallel,                      FiberPool        │    Adapter.EffectfulContract
 AtomicState,                      │             │
 Transaction,                      │             │
 AsyncComputation                  │             │
 Command                           ├────────────┐│
                                   │            ││
                              ┌────┴────┐       ││
                           Channel    Task      ││
                              │                 ││
                            Brook               ││
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
defmodule Onboarding do
  use Skuld.Syntax

  alias Skuld.Repo
  alias Skuld.Effects.{Fresh, Reader, Writer}

  defcomp register(params) do
    config <- Reader.ask()
    id <- Fresh.fresh_uuid()
    {:ok, user} <- Repo.insert(User.changeset(%{id: id, name: params.name, tier: config.default_tier}))
    _ <- Writer.tell(:events, %UserRegistered{user_id: id})
    {:ok, user}
  end
end
```

Run with production handlers:

```elixir
# One-time setup: generate an Ecto adapter for the Repo contract
defmodule MyApp.Repo.Port do
  use Skuld.Repo.Ecto, repo: MyApp.Repo
end

# Wire everything up:
Onboarding.register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_uuid7_handler()
|> Port.with_handler(%{Skuld.Repo.Effectful => MyApp.Repo.Port})
|> Writer.with_handler([], tag: :events, output: fn r, raw ->
  MyApp.EventBus.publish(Enum.reverse(raw))
  r
end)
|> Throw.with_handler()
|> Comp.run!()
```

Run with test handlers — same code, fully deterministic, no database:

```elixir
Onboarding.register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_test_handler()
|> Repo.InMemory.with_handler(Repo.InMemory.new())
|> Writer.with_handler([], tag: :events, output: fn r, raw -> {r, Enum.reverse(raw)} end)
|> Throw.with_handler()
|> Comp.run!()
```

`Repo.InMemory` is a closed-world in-memory store with read-after-write
consistency. Records created during the test are immediately readable by
subsequent `Repo.get` / `Repo.get_by` calls — no mocks, no stubs.

## Installation

```elixir
def deps do
  [
    {:skuld, "~> 0.3"}
  ]
end
```

## Where next?

| If you want to... | Read |
|---|---|
| Understand the problem effects solve | [Why Effects?](docs/why.md) |
| See how handlers make testing deterministic | [How Effects Work](docs/what.md) |
| Try your first computation | [Getting Started](docs/getting-started.md) |
| Eliminate N+1 queries | [Query & Batching](docs/advanced/query-batching.md) |
| Run computations concurrently | [Fibers & Concurrency](docs/advanced/fibers-concurrency.md) |
| Build hex boundaries with swappable backends | [Hexagonal Architecture](docs/recipes/hexagonal-architecture.md) |
| Serialise computations for resumable workflows | [EffectLogger](docs/advanced/effect-logger.md) |
| Explore all effects and handlers | [Full documentation](docs/getting-started.md) |

## License

MIT License — see [LICENSE](LICENSE) for details.

<!-- nav:footer:start -->

---

[Getting Started >](docs/getting-started.md)
<!-- nav:footer:end -->
