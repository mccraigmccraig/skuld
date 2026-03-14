# Skuld

[![Test](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/skuld.svg)](https://hex.pm/packages/skuld)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/skuld/)

Evidence-passing Algebraic Effects for Elixir.

Skuld is a clean, efficient implementation of Algebraic Effects using evidence-passing
style with CPS (continuation-passing style) for control effects. It provides scoped
handlers, composable effect stacks, and a library of useful effects.

Algebraic effects add an architectural layer between pure and side-effecting code:
instead of just pure functions and side-effecting functions, you have pure functions,
effectful functions, and side-effecting handlers. Domain code is written with effects
but remains pure - the same code runs with test handlers (pure, in-memory) or
production handlers (real I/O). This enables clean separation of concerns,
property-based testing, and serializable coroutines for durable computation.

Skuld's library of effects aims to provide primitives broad enough that most domain
computations can use effectful operations instead of side-effecting ones. Here are
some common side-effecting operations and their effectful equivalents:

| Side-effecting operation        | Effectful equivalent         |
|---------------------------------|------------------------------|
| Configuration / environment     | Reader                       |
| Process dictionary              | State, Writer                |
| Random values                   | Random                       |
| Generating IDs (UUIDs)          | Fresh                        |
| Concurrent fibers / streaming   | FiberPool, Channel, Brook    |
| Run effects from LiveView       | AsyncComputation             |
| DB writes & transactions        | DB                           |
| Batched DB reads (FiberPool)    | DB.Batch                     |
| Blocking calls to external code | Port, Port.Contract          |
| Effectful code from plain code  | Port.Provider                |
| Decider pattern                 | Command, EventAccumulator    |
| Serializable coroutines         | EffectLogger                 |
| Raising exceptions              | Throw                        |
| Resource cleanup (try/finally)  | Bracket                      |
| Control flow                    | Yield                        |
| Lists of effectful computations | FxList, FxFasterList         |

## Documentation

- **[Syntax](docs/syntax.md)** - Computations, the `comp` block, binds, auto-lifting, `else`/`catch` clauses, `defcomp`
- **[Debugging](docs/debugging.md)** - Stacktraces, exception handling, `try_catch`, `IThrowable`
- **Effects**
  - [State & Environment](docs/effects-state-environment.md) - State, Reader, Writer, tagged usage, scoped transforms
  - [Control Flow](docs/effects-control-flow.md) - Throw, Bracket, Yield, Yield.respond
  - [Collections](docs/effects-collections.md) - FxList, FxFasterList
  - [Value Generation](docs/effects-value-generation.md) - Fresh, Random
  - [Concurrency](docs/effects-concurrency.md) - AtomicState, Parallel, AsyncComputation, FiberPool, Channel, Brook
  - [Persistence & Data](docs/effects-persistence.md) - DB, DB.Batch, Command, EventAccumulator
  - [Port](docs/effects-port.md) - Port, Port.Contract, Port.Provider
  - [Serializable Coroutines](docs/effect-logger.md) - EffectLogger
- **[Property-Based Testing](docs/testing.md)** - Testing effectful code with pure handlers
- **[Architecture](docs/architecture.md)** - Design, comparison with Freyja
- **[Performance](docs/performance.md)** - Benchmarks and analysis

## Features

- **Evidence-passing style**: Handlers are looked up directly from a map in the
  dynamic environment
- **CPS for control effects**: Enables proper support for control flow effects
  like Yield and Throw
- **Scoped handlers**: Handlers are automatically installed/restored with proper
  cleanup
- **Composable**: Multiple effects can be stacked and composed naturally
- **Single type**: Single unified `computation` type and `comp` macro for all
  effectful code - ideal for dynamic languages
- **Auto-lifting**: Plain values are automatically lifted to computations,
  enabling ergonomic patterns like `if` without `else` and implicit final returns

## Installation

Add `skuld` to your list of dependencies in `mix.exs` (see the [Hex package](https://hex.pm/packages/skuld) for the current version):

```elixir
def deps do
  [
    {:skuld, "~> x.y"}
  ]
end
```

## Demo Application

See [TodosMcp](https://github.com/mccraigmccraig/todos_mcp) - a
voice-controllable todo application built with Skuld. It demonstrates how
command/query structs combined with algebraic effects enable trivial LLM
integration and property-based testing. Try it live at
https://todos-mcp-lu6h.onrender.com/

## Quick Start

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, Reader, Writer, Throw, Yield}

# Define a computation using the comp macro
defmodule Example do
  defcomp example() do
    # Read from Reader effect
    config <- Reader.ask()

    # Get and update State
    count <- State.get()
    _ <- State.put(count + 1)

    # Write to Writer effect
    _ <- Writer.tell("processed item #{count}")

    {config, count}  # final expression auto-lifted (no return needed)
  end
end

# Run with handlers installed
Example.example()
  |> Reader.with_handler(:my_config)
  |> State.with_handler(0, output: fn r, st -> {r, {:final_state, st}} end)
  |> Writer.with_handler([], output: fn r, w -> {r, {:log, w}} end)
  |> Comp.run!()

#=> {{{:my_config, 0}, {:final_state, 1}}, {:log, ["processed item 0"]}}
```

See the [Syntax guide](docs/syntax.md) for full details on the `comp` block,
pattern matching, error handling, and more.

## License

MIT License - see [LICENSE](LICENSE) for details.
