# skuld_process

<!-- nav:header:start -->
[Parallel >](docs/effects/parallel.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Multi-process execution for Skuld — true BEAM-process parallelism and
process-level shared mutable state. Use when you need real parallelism
across CPU cores, or when forked tasks need to share state without
copying `env`.

## What's included

- **`Skuld.Effects.Parallel`** — fork-join concurrency using
  `Task.Supervisor`. `Parallel.all` runs computations in separate BEAM
  processes and collects results; `Parallel.race` returns the first to
  complete and cancels the rest; `Parallel.map` applies a function over
  items concurrently. A `with_sequential_handler` runs everything
  synchronously for deterministic testing.
- **`Skuld.Effects.AtomicState`** — thread-safe mutable state for
  concurrent contexts. Unlike regular `State` (stored in `env.state`
  and copied when forking), AtomicState uses an external `Agent`
  (production) or `env.state` (testing via `Sync` handler). Supports
  multiple independent tagged states and compare-and-swap operations.

## When to use Parallel vs FiberPool

`FiberPool` (from `skuld_concurrency`) runs fibers cooperatively within a
single BEAM process — ideal for I/O-bound work. `Parallel` spawns real
BEAM processes — use for CPU-bound work or when you need OS-level
scheduling. Both compose: FiberPool-managed fibers can fan out with
`Parallel` when they hit CPU-heavy sections.

## Installation

```elixir
def deps do
  [
    {:skuld_process, "~> 0.32"}
  ]
end
```

## Example: parallel fan-out with shared state

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Parallel, AtomicState, Throw}

comp do
  # Initialize shared counter
  _ <- AtomicState.put(:processed, 0)

  # Process items in parallel
  _ <- Parallel.map(1..10, fn i ->
    comp do
      result <- do_expensive_work(i)
      _ <- AtomicState.modify(:processed, &(&1 + 1))
      result
    end
  end)

  count <- AtomicState.get(:processed)
  count
end
|> AtomicState.Agent.with_handler(0, tag: :processed)
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> 10
```

## Further reading

- [Parallel](https://hexdocs.pm/skuld_process/parallel.html) — operations, error handling, test handler
- [AtomicState](https://hexdocs.pm/skuld_process/atomic-state.html) — tagged states, CAS, Agent vs Sync

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[Parallel >](docs/effects/parallel.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
