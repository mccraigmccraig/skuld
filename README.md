# Skuld

<!-- nav:header:start -->
[Why Effects? >](docs/why.md)
<!-- nav:header:end -->

[![Test](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/skuld.svg)](https://hex.pm/packages/skuld)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/skuld/)

Evidence-passing Algebraic Effects for Elixir.

## The problem

Between your pure business logic and your side-effecting infrastructure
sits the orchestration layer: "fetch the user, check permissions, load
their subscription, compute the price, write the invoice." This code
encodes your most important business rules, but it's tangled with
databases, APIs, and randomness - making it hard to test, hard to
refactor, and impossible to property-test.

## The insight

Skuld adds a layer between pure and side-effecting code: **effectful**
code. Domain logic *requests* effects (database access, randomness, error
handling) without performing them. Handlers decide what those requests
mean. The same orchestration code runs with real handlers in production
and pure in-memory handlers in tests - fully deterministic, trivially
testable.

## What Skuld solves

| Pain point                             | What Skuld does                                                            | More                                                                       |
|----------------------------------------|----------------------------------------------------------------------------|----------------------------------------------------------------------------|
| Orchestration code is untestable       | Swap handlers: same code runs in-memory with no DB, no network             | [Testing](docs/pain-points.md#testing-orchestration-code)                  |
| Stateful test doubles for complex flows | Reusable in-memory handlers with read-after-write consistency              | [Stateful testing](docs/pain-points.md#reusable-stateful-test-doubles)     |
| Non-deterministic UUIDs / randomness   | Fresh and Random have deterministic test handlers - same test, same values | [Determinism](docs/pain-points.md#deterministic-uuids-randomness-and-time) |
| N+1 queries                            | `deffetch` + `query` batch independent loads automatically                 | [Batching](docs/pain-points.md#automatic-query-batching)                   |
| Long-running workflows across restarts | EffectLogger serialises progress; resume from where you left off           | [Durable workflows](docs/pain-points.md#long-running-computations)         |
| LiveView multi-step operations         | AsyncComputation bridges effects into LiveView's process model             | [LiveView](docs/pain-points.md#liveview-multi-step-operations)             |
| Hexagonal architecture plumbing        | Port.Contract / Port.Adapter.Effectful - typed boundaries, no parameter threading | [Hex arch](docs/pain-points.md#clean-architecture-boundaries)              |

See [What Skuld Solves](docs/pain-points.md) for worked examples of each.

## Quick example

```elixir
defmodule Onboarding do
  use Skuld.Syntax

  alias Skuld.Repo
  alias Skuld.Effects.Writer

  defcomp register(params) do
    # Read configuration from the environment
    config <- Reader.ask()

    # Generate a deterministic ID
    id <- Fresh.fresh_uuid()

    # Database call via the built-in Repo contract/facade
    {:ok, user} <- Repo.insert(User.changeset(%{id: id, name: params.name, tier: config.default_tier}))

    # Accumulate domain events
    _ <- Writer.tell(:events, %UserRegistered{user_id: id}) |> Comp.then_do(Comp.pure(:ok))

    {:ok, user}
  end
end
```

Run with production handlers:

```elixir
# Generate an Ecto adapter for the Repo contract (one-time setup):
defmodule MyApp.Repo.Port do
  use Skuld.Repo.Ecto, repo: MyApp.Repo
end

# Wire everything up:
Onboarding.register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_uuid7_handler()
|> Port.with_handler(%{Port.Repo => MyApp.Repo.Port})
|> Writer.with_handler([], tag: :events, output: fn r, raw ->
  MyApp.EventBus.publish(Enum.reverse(raw))
  r
end)
|> Throw.with_handler()
|> Comp.run!()
```

Run with test handlers — same code, fully deterministic, no database:

```elixir
alias Skuld.Repo
alias Skuld.Effects.Writer

Onboarding.register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_test_handler()
|> Repo.InMemory.with_handler(Repo.InMemory.new())
|> Writer.with_handler([], tag: :events, output: fn r, raw -> {r, Enum.reverse(raw)} end)
|> Throw.with_handler()
|> Comp.run!()
```

`Repo.InMemory` wraps `DoubleDown.Repo.InMemory` — a closed-world in-memory
store with read-after-write consistency. Records created during the test
are immediately readable by subsequent `Repo.get` / `Repo.get_by` calls.
No match patterns to maintain, no ad-hoc port keys — the same `Repo.insert`,
`Repo.get`, and `Repo.update` functions used in production.

## Installation

Add `skuld` to your dependencies in `mix.exs` (see [Hex](https://hex.pm/packages/skuld) for the current version):

```elixir
def deps do
  [
    {:skuld, "~> 0.3"}
  ]
end
```

## What can it do?

### Foundational effects

Effects that solve problems every Elixir developer recognises. They feel
like well-structured Elixir code with better testability.

| Side-effecting operation        | Effectful equivalent         |
|---------------------------------|------------------------------|
| Configuration / environment     | Reader                       |
| Process dictionary / state      | State, Writer                |
| Random values                   | Random                       |
| Generating IDs (UUIDs)          | Fresh                        |
| Transactions                    | Transaction                  |
| Blocking calls to external code | Port, Port.Contract          |
| Effectful code from plain code  | Port.Adapter.Effectful       |
| Mutation dispatch               | Command                      |
| Domain event collection         | Writer (tell, listen, peek, censor) |
| Fork-join concurrency           | Parallel                     |
| Thread-safe state               | AtomicState                  |
| Effects from LiveView           | AsyncComputation             |
| Raising exceptions              | Throw                        |
| Resource cleanup (try/finally)  | Bracket                      |
| Effectful list operations       | FxList, FxFasterList         |

### Advanced effects

Effects that use cooperative fibers and continuations to do things that
aren't possible with standard BEAM patterns. You don't need these to
get value from Skuld - the foundational effects stand on their own.

| Pattern                         | Effectful equivalent         |
|---------------------------------|------------------------------|
| Coroutines / suspend-resume     | Yield                        |
| Cooperative fibers              | FiberPool                    |
| Bounded channels                | Channel                      |
| Streaming with backpressure     | Brook                        |
| Automatic N+1 query batching    | query, deffetch, Query.Cache |
| Serializable coroutines         | EffectLogger                 |

## Documentation

**New to algebraic effects?** Start with
[Why Effects?](docs/why.md) - the problem, explained without jargon.

**Ready to code?** Jump to
[Getting Started](docs/getting-started.md) for your first computation.

### Full documentation

| Layer | Topic | Description |
|-------|-------|-------------|
| 1 | [Why Effects?](docs/why.md) | The problem effects solve |
| 2 | [The Concept](docs/what.md) | How algebraic effects work |
|   | [What Skuld Solves](docs/pain-points.md) | Concrete problems, worked examples |
| 3 | [Getting Started](docs/getting-started.md) | Your first computation |
| 4 | [Syntax In Depth](docs/syntax.md) | `comp`, `else`, `catch`, `defcomp` |
| 5 | **Foundational Effects** | |
|   | [State & Environment](docs/effects/state-environment.md) | State, Reader, Writer |
|   | [Error Handling](docs/effects/error-handling.md) | Throw, Bracket |
|   | [Value Generation](docs/effects/value-generation.md) | Fresh, Random |
|   | [Collections](docs/effects/collections.md) | FxList, FxFasterList |
|   | [Concurrency](docs/effects/concurrency.md) | Parallel, AtomicState, AsyncComputation |
|   | [Persistence](docs/effects/persistence.md) | Transaction, Command |
|   | [External Integration](docs/effects/external-integration.md) | Port, Port.Contract, Port.Adapter.Effectful |
| 6 | **Advanced Effects** | |
|   | [Yield](docs/advanced/yield.md) | Coroutines |
|   | [Fibers & Concurrency](docs/advanced/fibers-concurrency.md) | FiberPool, Channel, Brook |
|   | [Query & Batching](docs/advanced/query-batching.md) | Automatic N+1 prevention |
|   | [EffectLogger](docs/advanced/effect-logger.md) | Serializable coroutines |
| 7 | **Recipes** | |
|   | [Testing](docs/recipes/testing.md) | Property-based testing with effects |
|   | [Hexagonal Architecture](docs/recipes/hexagonal-architecture.md) | Port.Contract + Port.Adapter.Effectful |
|   | [Decider Pattern](docs/recipes/decider-pattern.md) | Event-sourced domain logic |
|   | [Handler Stacks](docs/recipes/handler-stacks.md) | Composing production & test stacks |
|   | [LiveView](docs/recipes/liveview.md) | Multi-step wizards |
|   | [Durable Workflows](docs/recipes/durable-workflows.md) | Persist-and-resume with EffectLogger |
|   | [Data Pipelines](docs/recipes/data-pipelines.md) | Streaming with Brook |
|   | [Batch Loading](docs/recipes/batch-loading.md) | N+1-free data access |
| 8 | **Internals** | |
|   | [Internals](docs/internals.md) | Implementation details |
|   | [Reference](docs/reference.md) | API reference and comparisons |

## Demo Application

See [TodosMcp](https://github.com/mccraigmccraig/todos_mcp) - a
voice-controllable todo application built with Skuld. It demonstrates
command/query structs with algebraic effects for LLM integration and
property-based testing. Try it live at
https://todos-mcp-lu6h.onrender.com/

## License

MIT License - see [LICENSE](LICENSE) for details.

<!-- nav:footer:start -->

---

[Why Effects? >](docs/why.md)
<!-- nav:footer:end -->
