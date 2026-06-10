# skuld_process

<!-- nav:header:start -->
[Parallel >](docs/effects/parallel.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Multi-process execution for Skuld: parallel fan-out and process-level mutable state.

## What's included

- **`Skuld.Effects.Parallel`** — fork-join concurrency with `all`, `race`, and `map`
- **`Skuld.Effects.AtomicState`** — thread-safe state via Agent (production) or env.state (testing)

## Installation

```elixir
def deps do
  [
    {:skuld_process, "~> 0.32"}
  ]
end
```

## Quick start

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Parallel, Throw}

comp do
  Parallel.all([
    comp do expensive_work(:a) end,
    comp do expensive_work(:b) end,
    comp do expensive_work(:c) end
  ])
end
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [:result_a, :result_b, :result_c]
```

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[Parallel >](docs/effects/parallel.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
