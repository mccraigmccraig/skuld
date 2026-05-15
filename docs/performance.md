# Performance

<!-- nav:header:start -->
[< Quick Reference](quick-reference.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [State, Reader & Writer >](effects/state-reader-writer.md)
<!-- nav:header:end -->

Each effect invocation involves handler lookup (O(1) map atom key),
continuation creation, and function call overhead. Operations use compact
representations — bare atoms for 0-arg ops, small tuples for ops with
args. No struct allocation on the hot path.

When effects implement `ITotalLinearHandler` (like `State`),
the `comp` macro can emit an inline continuation path that
skips `Comp.bind/2` closure allocation entirely — eliminating the
closure-creation cost from the per-operation overhead.

## Benchmarks

A loop incrementing a counter via `State.get()`/`State.put(n + 1)` at
N=10,000 (run with `MIX_ENV=prod` for consolidated protocols). The
"+catches" variants add the same catch frames Skuld uses for error
handling — this is the cost real-world Elixir code with `try`/`rescue`
already pays:

| Approach                                  | Time    | Per-op   |
|-------------------------------------------|---------|----------|
| Pure tail recursion                       | 189 µs  | 0.019 us |
| Pure tail recursion + catches             | 263 µs  | 0.026 us |
| Simple state monad                        | 164 µs  | 0.016 us |
| Simple state monad + catches              | 1.71 ms | 0.171 us |
| Evidence-passing (reader)                 | 318 µs  | 0.032 us |
| Evidence-passing (reader) + catches       | 863 µs  | 0.086 us |
| Evidence-passing (reader + CPS)           | 347 µs  | 0.035 us |
| Evidence-passing (reader + CPS) + catches | 1.59 ms | 0.159 us |
| **Skuld** (nested binds, CPS path)        | 2.18 ms | 0.218 us |
| **Skuld/Comp** (comp macro, inline)       | 1.42 ms | 0.142 us |
| Freyja                                    | ~10 ms  | ~1 us    |

Two Skuld variants are shown:

- **Skuld** — uses nested `Comp.bind/2` calls (the CPS path)
- **Skuld/Comp** — uses the `comp` macro with the total+linear
  inline optimisation (the optimal path)

Skuld/Comp is **1.5× faster** than the nested-bind Skuld path.

The apples-to-apples comparison is Skuld/Comp vs evidence-passing CPS +
catches (both have catch frames): Skuld/Comp achieves **0.89×** — it is
**faster** than hand-written evidence-passing CPS + catches. The comp
macro path eliminates bind overhead entirely, matching the raw CPS
baseline.

## Where the overhead comes from

Nearly all the gap between Skuld/Comp and bare evidence-passing CPS is
**catch frames** — the same `try`/`catch` mechanism every real-world
Elixir application already uses for error handling:

| Baseline                                  | us/op | vs bare CPS |
|-------------------------------------------|-------|-------------|
| Evidence-passing (reader) + CPS           | 0.035 | 1.0×        |
| Evidence-passing (reader) + CPS + catches | 0.159 | **4.5×**    |
| **Skuld/Comp** (comp macro inline)        | 0.142 | 4.1×        |
| **Skuld** (nested binds)                  | 0.218 | 6.2×        |

Catch frames account for **4.5×** of the total overhead. Skuld/Comp
adds **0.89×** — indistinguishable from the catch-only baseline.

## Iteration strategies

Effectful iteration over collections at N=1,000:

| Strategy     | Time   | Per-op  | Notes                                     |
|--------------|--------|---------|-------------------------------------------|
| FxFasterList | 115 us | 0.12 us | Fastest; no Yield/Suspend support         |
| Yield        | 160 us | 0.16 us | Use when you need interruptible iteration |
| FxList       | 167 us | 0.17 us | Full Yield/Suspend support                |

All three maintain constant per-operation cost as N grows.

## Protocol consolidation

Elixir consolidates protocols only in `:prod` mode. In `:dev` and
`:test`, protocol dispatch uses a slow dynamic lookup (~75 us per call)
instead of the compiled dispatch table used in production. Skuld
dispatches through the `ISentinel` protocol in `Comp.run/1`.

Always benchmark with `MIX_ENV=prod` to get production-representative
numbers. You can also set `consolidate_protocols: true` in your
`mix.exs` project config temporarily for benchmarking in dev mode.

## Running the benchmarks

```bash
# Main benchmark (approaches 1-10)
MIX_ENV=prod mix run bench/skuld_benchmark.exs

# Progressive overhead (adds features one at a time)
MIX_ENV=prod mix run bench/overhead_progressive.exs

# Brook vs GenStage comparison
MIX_ENV=prod mix run bench/brook_vs_genstage.exs
```

<!-- nav:footer:start -->

---

[< Quick Reference](quick-reference.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [State, Reader & Writer >](effects/state-reader-writer.md)
<!-- nav:footer:end -->
