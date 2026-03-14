# Performance

Benchmark comparing Skuld against pure baselines and minimal effect implementations.
Run with `mix run bench/skuld_benchmark.exs`.

**What's being measured:** A loop that increments a counter from 0 to N using
`State.get()` / `State.put(n + 1)` operations. This exercises the core effect
invocation path repeatedly, measuring per-operation overhead.

## Core Benchmark

| Target | Pure/Rec | Monad  | Evf    | Evf/CPS | Skuld/Nest | Skuld/FxFL |
|--------|----------|--------|--------|---------|------------|------------|
| 500    | 4 us     | 10 us  | 17 us  | 17 us   | 141 us     | 54 us      |
| 1000   | 28 us    | 55 us  | 56 us  | 58 us   | 255 us     | 166 us     |
| 2000   | 34 us    | 78 us  | 91 us  | 97 us   | 558 us     | 325 us     |
| 5000   | 82 us    | 189 us | 244 us | 258 us  | 1.42 ms    | 836 us     |
| 10000  | 145 us   | 157 us | 298 us | 325 us  | 2.3 ms     | 960 us     |

**Implementations compared:**

- **Pure/Rec** - Non-effectful baseline using tail recursion with map state
- **Monad** - Simple state monad (`fn state -> {val, state} end`) with no effect system
- **Evf** - Flat evidence-passing, direct-style (no CPS) - can't support control effects
- **Evf/CPS** - Flat evidence-passing with CPS - isolates CPS overhead (~1.1x vs Evf)
- **Skuld/Nest** - Skuld with nested `Comp.bind` calls (typical usage pattern)
- **Skuld/FxFL** - Skuld with `FxFasterList` iteration (optimized for collections)

## Iteration Strategies

| Target | FxFasterList          | FxList               | Yield                |
|--------|-----------------------|----------------------|----------------------|
| 1000   | 97 us (0.10 us/op)    | 200 us (0.20 us/op)  | 147 us (0.15 us/op)  |
| 5000   | 492 us (0.10 us/op)   | 959 us (0.19 us/op)  | 762 us (0.15 us/op)  |
| 10000  | 1.02 ms (0.10 us/op)  | 2.71 ms (0.27 us/op) | 1.52 ms (0.15 us/op) |
| 50000  | 5.1 ms (0.10 us/op)   | -                    | 7.58 ms (0.15 us/op) |
| 100000 | 10.02 ms (0.10 us/op) | -                    | 14.9 ms (0.15 us/op) |

**Iteration options:**

- **FxFasterList** - Uses `Enum.reduce_while`, fastest option (~2x faster than FxList)
- **FxList** - Uses `Comp.bind` chains, supports full Yield/Suspend resume semantics
- **Yield** - Coroutine-style suspend/resume, use when you need interruptible iteration

All three maintain constant per-operation cost as N grows.

## Key Takeaways

1. **CPS overhead is minimal** - Evf/CPS is only ~1.1x slower than direct-style Evf
2. **Skuld overhead** (~7x vs Evf/CPS) comes from scoped handlers, exception handling, and auto-lifting
3. **FxFasterList** is the fastest iteration strategy when you don't need Yield semantics
4. **Per-op cost is constant** - no quadratic blowup at scale

## Real-World Perspective

These benchmarks represent a **worst-case scenario** where computations do almost
nothing except exercise the effects machinery. In practice, algebraic effects
compose real work - serialization, domain calculations, transcoding - where actual
computation dominates execution time.

For example, JSON encoding a moderate payload takes 10-100us, and domain validation
or business logic involves similar compute. Compared to Skuld's ~0.1us per effect
invocation, even dozens of effect operations add negligible overhead to real
workloads. The architectural benefits - testability, composability, separation of
concerns - far outweigh the microsecond-level cost.
