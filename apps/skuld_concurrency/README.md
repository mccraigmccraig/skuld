# skuld_concurrency

<!-- nav:header:start -->
[Coroutine >](docs/effects/coroutine.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Cooperative concurrency for the Skuld effect system — coroutines, a
fiber pool scheduler, streaming, and process bridging. Everything runs
in-process with structured concurrency; no GenServers, no supervision
trees, no message-passing overhead.

## What's included

- **`Skuld.Coroutine`** — a cooperative fiber primitive. Wrap a computation
  into a typed state machine that can be paused (via `Yield`), resumed, and
  cancelled. The building block everything else schedules.
- **`Skuld.Effects.FiberPool`** — a cooperative scheduler. Runs fibers
  concurrently within a single BEAM process, with `scope` for structured
  concurrency and deadlock detection. When fibers `await` each other,
  the scheduler automatically steps the dependency graph.
- **`Skuld.Effects.Channel`** — bounded channels with backpressure and
  error propagation. `put` suspends the fiber when full; `take` suspends
  when empty. Errors are sticky — a poisoned channel propagates to all
  consumers.
- **`Skuld.Effects.Brook`** — high-level streaming API built on channels.
  `map`, `filter`, `flat_map`, `reduce` — each combinator can run with
  configurable concurrency. Integrates transparently with query batching.
- **`Skuld.AsyncCoroutine`** — bridges effectful computations across
  processes via messages. The primary LiveView integration point: mount
  starts a runner, `handle_info` resumes it with user input.
- **`Skuld.Effects.Task`** — true BEAM-process parallelism. `Task.async`
  runs a computation in a separate process; the FiberPool scheduler
  tracks it alongside cooperative fibers.

## Installation

```elixir
def deps do
  [
    {:skuld_concurrency, "~> 0.32"}
  ]
end
```

## Example: concurrent stream processing

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Yield, Channel, Brook, FiberPool}

# A stream of work items
source = 1..100 |> Enum.map(&"item-#{&1}")

comp do
  results <-
    Brook.from_enum(source)
    |> Brook.map(fn item ->
      comp do
        # Simulate async work on each item
        Yield.yield(item)
      end
    end, concurrency: 8)
    |> Brook.to_list()

  results
end
|> Yield.with_handler()
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
# 8 concurrent fibers, Channel provides backpressure, FiberPool schedules them all
```

## Further reading

- [Coroutine](https://hexdocs.pm/skuld_concurrency/coroutine.html) — fiber states and lifecycle
- [FiberPool](https://hexdocs.pm/skuld_concurrency/fiberpool.html) — scheduler and structured concurrency
- [Channel & Brook](https://hexdocs.pm/skuld_concurrency/channel-brook.html) — backpressure and streaming
- [AsyncCoroutine](https://hexdocs.pm/skuld_concurrency/async-coroutine.html) — LiveView integration
- [LiveView recipe](https://hexdocs.pm/skuld/liveview.html) — full LiveView example with AsyncCoroutine
- [Batch loading recipe](https://hexdocs.pm/skuld/batch-loading.html) — FiberPool + Query batching

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[Coroutine >](docs/effects/coroutine.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
