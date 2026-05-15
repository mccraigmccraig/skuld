# Performance

<!-- nav:header:start -->
[< Quick Reference](quick-reference.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [State, Reader & Writer >](effects/state-reader-writer.md)
<!-- nav:header:end -->

Skuld achieves near-parity with hand-written evidence-passing CPS.
Discounting BEAM `try/catch` overhead — irreducible and shared with all
Elixir applications — the additional framework overhead is minimal.

## Per-effect overhead

Progressive benchmarks starting from a bare CPS baseline and adding
Skuld features one at a time (N=10,000, `MIX_ENV=prod`):

| Step | Feature | vs catch baseline |
|------|---------|-------------------|
| S1 | + first catch frame | 1.0x (baseline) |
| S3 | + 2 more catches (3 total) | 1.25x |
| S6 | + struct operation args | 1.68x |
| S10 | Full Skuld (all features) | ~2.1–2.3x |

The largest single factor is BEAM `try/catch` frames (~0.163 µs/op for
the first frame), not Skuld's own machinery. Three catch frames per loop
iteration (call, bind, handler dispatch) account for most of the overhead
relative to raw CPS.

## Inline total+linear path

Effects implementing `ITotalLinearHandler` get an inline continuation
path in `comp do` blocks:

```elixir
# State is a total+linear handler — the comp macro emits inline
# continuations, skipping Comp.bind/2 closure allocation
comp do
  x <- State.get()
  y <- State.put(x + 1)
  y * 2
end
```

At N=10,000 this path is **1.5–1.8× faster** than the nested-bind
path and matches raw CPS within noise.

## Per-tag operation optimisation

Tagged effects (e.g. `State.get(:counter)`) use per-tag module-atom
signatures. The handler captures a precomputed state key at installation
time, eliminating per-operation key computation and struct allocation:

| Metric | Before (struct ops) | After (per-tag sig) |
|--------|---------------------|---------------------|
| S10 Full Skuld | 4.2–5.5x vs S0 | 2.6–2.7x vs S0 |

The improvement collapses multiple overhead sources simultaneously:
struct args, Change struct allocation, and state key computation are
all reduced by the handler closing over precomputed values.

## Data fetch benchmarks

Query batching benchmarks show FiberPool overhead at ~0.25 µs/op per
fiber. For realistic workloads (database queries at ~1 ms), the overhead
is noise. Automatic N+1 batching provides order-of-magnitude speedups
for multi-fetch operations.

## Where the overhead lives

The remaining vs-catch-baseline overhead (~2.1–2.3x) is composed of:

- Additional catch frames (~1.25x) — irreducible BEAM tax
- Struct argument allocation (~1.30x) — reduced by per-tag sigs
- Tuple state keys (~1.16x) — eliminated by per-tag sigs
- Env struct size and scoped machinery — negligible after inlining

## Optimisation summary

| Optimisation | Status | Impact |
|------------|--------|--------|
| `@compile {:inline, ...}` for hot-path wrappers | Implemented | Closed S9→S10 gap (~1.40x → 1.0x) |
| Per-tag module-atom sigs | Implemented | Reduced S10 from 4.2–5.5x to 2.6–2.7x |
| Total+linear inline continuation | Implemented | 1.5–1.8× over nested-bind; parity with raw CPS |
| Reduce Env struct size | Under investigation | Potential marginal gain |

<!-- nav:footer:start -->

---

[< Quick Reference](quick-reference.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [State, Reader & Writer >](effects/state-reader-writer.md)
<!-- nav:footer:end -->
