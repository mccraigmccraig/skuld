# Skuld

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

## Quick example

```elixir
defmodule Onboarding do
  use Skuld.Syntax

  defcomp register(params) do
    # Read configuration from the environment
    config <- Reader.ask()

    # Generate a deterministic ID
    id <- Fresh.fresh_uuid()

    # Use a port for the database call
    user <- UserRepo.create_user!(%{id: id, name: params.name, tier: config.default_tier})

    # Accumulate domain events
    _ <- EventAccumulator.emit(%UserRegistered{user_id: id})

    {:ok, user}
  end
end
```

Run with production handlers:

```elixir
Onboarding.register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_uuid7_handler()
|> Port.with_handler(%{UserRepo => UserRepo.Ecto})
|> EventAccumulator.with_handler(output: fn r, events ->
  MyApp.EventBus.publish(events)
  r
end)
|> Throw.with_handler()
|> Comp.run!()
```

Run with test handlers - same code, no database, fully deterministic:

```elixir
Onboarding.register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_test_handler()
|> Port.with_test_handler(%{
  UserRepo.key(:create_user, %{id: _, name: "Alice", tier: :free}) =>
    {:ok, %User{id: "test-uuid", name: "Alice", tier: :free}}
})
|> EventAccumulator.with_handler(output: fn r, events -> {r, events} end)
|> Throw.with_handler()
|> Comp.run!()
```

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
| DB writes & transactions        | DB                           |
| Blocking calls to external code | Port, Port.Contract          |
| Effectful code from plain code  | Port.Provider                |
| Mutation dispatch               | Command                      |
| Domain event collection         | EventAccumulator             |
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
| 3 | [Getting Started](docs/getting-started.md) | Your first computation |
| 4 | [Syntax In Depth](docs/syntax.md) | `comp`, `else`, `catch`, `defcomp` |
| 5 | **Foundational Effects** | |
|   | [State & Environment](docs/effects/state-environment.md) | State, Reader, Writer |
|   | [Error Handling](docs/effects/error-handling.md) | Throw, Bracket |
|   | [Value Generation](docs/effects/value-generation.md) | Fresh, Random |
|   | [Collections](docs/effects/collections.md) | FxList, FxFasterList |
|   | [Concurrency](docs/effects/concurrency.md) | Parallel, AtomicState, AsyncComputation |
|   | [Persistence](docs/effects/persistence.md) | DB, Command, EventAccumulator |
|   | [External Integration](docs/effects/external-integration.md) | Port, Port.Contract, Port.Provider |
| 6 | **Advanced Effects** | |
|   | [Yield](docs/advanced/yield.md) | Coroutines |
|   | [Fibers & Concurrency](docs/advanced/fibers-concurrency.md) | FiberPool, Channel, Brook |
|   | [Query & Batching](docs/advanced/query-batching.md) | Automatic N+1 prevention |
|   | [EffectLogger](docs/advanced/effect-logger.md) | Serializable coroutines |
| 7 | **Recipes** | |
|   | [Testing](docs/recipes/testing.md) | Property-based testing with effects |
|   | [Hexagonal Architecture](docs/recipes/hexagonal-architecture.md) | Port.Contract + Port.Provider |
|   | [Decider Pattern](docs/recipes/decider-pattern.md) | Event-sourced domain logic |
|   | [Handler Stacks](docs/recipes/handler-stacks.md) | Composing production & test stacks |
|   | [LiveView](docs/recipes/liveview.md) | Multi-step wizards |
|   | [Durable Workflows](docs/recipes/durable-workflows.md) | Persist-and-resume with EffectLogger |
|   | [Data Pipelines](docs/recipes/data-pipelines.md) | Streaming with Brook |
|   | [Batch Loading](docs/recipes/batch-loading.md) | N+1-free data access |

## Demo Application

See [TodosMcp](https://github.com/mccraigmccraig/todos_mcp) - a
voice-controllable todo application built with Skuld. It demonstrates
command/query structs with algebraic effects for LLM integration and
property-based testing. Try it live at
https://todos-mcp-lu6h.onrender.com/

## License

MIT License - see [LICENSE](LICENSE) for details.
