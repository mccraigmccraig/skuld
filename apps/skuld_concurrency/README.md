# skuld_concurrency

<!-- nav:header:start -->
[Coroutine >](docs/effects/coroutine.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Cooperative coroutines, streaming, and concurrency for the Skuld effect system.

## What's included

- **`Skuld.Coroutine`** — cooperative fiber primitive with typed states
- **`Skuld.Effects.FiberPool`** — cooperative scheduler with structured concurrency
- **`Skuld.Effects.Channel`** — bounded channels with backpressure and error propagation
- **`Skuld.Effects.Brook`** — streaming combinators (map, filter, flat_map, etc.)
- **`Skuld.AsyncCoroutine`** — cross-process bridge for LiveView and GenServer
- **`Skuld.Effects.Task`** — BEAM process parallelism within FiberPool

## Installation

```elixir
def deps do
  [
    {:skuld_concurrency, "~> 0.32"}
  ]
end
```

## Quick start

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Yield, FiberPool}

comp do
  results <- FiberPool.map(1..4, fn i ->
    comp do
      Yield.yield(i * 2)
    end
  end)
  results
end
|> Yield.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
#=> [2, 4, 6, 8]
```

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[Coroutine >](docs/effects/coroutine.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
