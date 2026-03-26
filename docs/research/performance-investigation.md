# Performance Investigation

<!-- nav:header:start -->
[< Reference](../reference.md) | [Index](../../README.md)
<!-- nav:header:end -->

This document records our investigation into Skuld's per-effect overhead,
what causes it, and where realistic optimisation opportunities exist.

## Method

We built a [progressive benchmark](../../bench/overhead_progressive.exs)
that starts from a flat evidence-passing CPS baseline (the minimal
implementation of the same algebraic-effects idea) and adds one Skuld
feature at a time, measuring the marginal cost of each addition.
All numbers were collected at N=10 000 with `MIX_ENV=prod`
(consolidated protocols).

## Progressive overhead results

| Step | Feature added                     | us/op | vs prev   | vs baseline |
|------|-----------------------------------|-------|-----------|-------------|
| S0   | evf_cps baseline                  | 0.072 | —         | 1.0x        |
| S1   | + first catch frame (`call`)      | 0.163 | **2.26x** | **2.3x**    |
| S2   | + catch in `bind`                 | 0.165 | 1.01x     | 2.3x        |
| S3   | + catch on handler dispatch       | 0.204 | **1.24x** | 2.8x        |
| S4   | + `is_function` guard             | 0.206 | 1.01x     | 2.9x        |
| S5   | + struct env (`%Env{}`)           | 0.211 | 1.02x     | 2.9x        |
| S6   | + struct args (`%Get{}`/`%Put{}`) | 0.274 | **1.30x** | **3.8x**    |
| S7   | + accessor functions              | 0.278 | 1.01x     | 3.9x        |
| S8   | + `%Change{}` struct on put       | 0.296 | 1.06x     | 4.1x        |
| S9   | + `{Mod, tag}` state keys         | 0.342 | **1.16x** | 4.8x        |
| S10  | Full Skuld                        | 0.479 | **1.40x** | **6.7x**    |

## The catch frame: a tax you were already paying

The single largest contributor is the first `try/catch` frame (S0→S1:
**2.26x**). But this is not Skuld-specific overhead — it is a property
of the BEAM VM, and any real Elixir code that does error handling
(which is essentially all of it) already pays this cost.

### Why the first catch is expensive

The raw BEAM JIT instructions for `try`/`try_end` are only 3+2 native
x86 instructions (increment/decrement `Process.catches`, store/clear a
catch tag in a Y register). That does not explain a 2.26x slowdown.

The real cost is **structural** — side-effects of having a catch frame
at all:

1. **Forced stack frame allocation.** A `try/catch` requires at least
   one Y register for the catch tag. This forces the compiler to emit
   `allocate N, Live` (which includes a GC test: `lea`, `cmp`, `jbe`,
   plus stack pointer adjustment) and a matching `deallocate`. Without
   any catch frame, a tight CPS loop can live entirely in X registers
   with no stack frame.

2. **Register spilling.** All live X registers (fast registers) must be
   saved to Y registers (stack) before the try body, because BEAM
   exception dispatch only preserves Y registers. Each live variable
   means an extra `mov` instruction.

3. **JIT type-optimisation barrier.** The JIT's type inference
   (`beam_ssa_type`) cannot propagate type information across
   `try/catch` boundaries. According to the
   [OTP 26 JIT optimisation blog post][otp26-jit], type-based
   optimisations can reduce instruction counts from 14→5 for simple
   operations — but these optimisations are blocked by catch
   boundaries.

[otp26-jit]: https://www.erlang.org/blog/more-optimizations/

### Why nested catches are nearly free

Once the first catch has already forced a stack frame, caused register
spilling, and broken the type-optimisation boundary, each additional
catch tag costs only 5 native instructions (3 setup + 2 teardown).
This matches our measurements: S1→S2 = 1.01x, S2→S3 = 1.24x.

The S2→S3 step (1.24x) is slightly higher than S1→S2, likely because
the third catch frame at that nesting depth introduces additional
register pressure or live variables that need spilling.

### Prior art

We searched for published benchmarks of BEAM `try/catch` happy-path
overhead and found **no comparable measurements**. The closest
references:

- **ElixirForum discussion** — Robert Virding confirms `try/catch` and
  `try/rescue` use the same underlying Erlang mechanism, but no numbers
  are given.
- **Erlang Efficiency Guide** — advises against using exceptions for
  flow control, but does not quantify happy-path overhead.
- **OTP GitHub issues** — no issues filed about `try/catch`
  performance.

Our 2.26x measurement appears to be novel.

### Reframing the overhead

Since the first catch frame is a BEAM-wide tax that any error-handling
code pays, it is more accurate to measure Skuld's *additional* overhead
**relative to code that already has a catch frame**. That means the
relevant baseline is S1 (0.163 us/op), not S0 (0.072 us/op):

| Step | Feature                           | vs S1 (catch baseline) |
|------|-----------------------------------|------------------------|
| S1   | catch baseline                    | 1.0x                   |
| S3   | + 2 more catches                  | 1.25x                  |
| S6   | + struct args                     | 1.68x                  |
| S9   | + tuple keys + Change + accessors | 2.10x                  |
| S10  | Full Skuld                        | **2.94x**              |

**Skuld's own overhead is ~2.9x over code that already has a catch
frame**, not 6.7x. The major contributors are struct allocation
(~1.30x step) and the full-Skuld machinery (~1.40x step).

## Decomposing the full-Skuld gap (S9→S10: 1.40x)

S9 is a hand-rolled simulation that uses the same data structures as
Skuld (struct env, struct args, Change, tuple keys) but skips the real
Skuld machinery. Comparing the hot paths identifies what causes the
remaining 1.40x:

### Per-iteration overhead (on every get/put cycle)

| Source | Extra work | Count per iter |
|--------|-----------|----------------|
| `Env.get_state!/2` wrapper fn call | 1 function call frame | 2 (get + put) |
| `Env.put_state/3` wrapper fn call  | 1 function call frame | 1 (put only)  |
| `Change.new/2` fn call vs literal  | 1 function call frame | 1 (put only)  |
| 4-field `%Env{}` struct copy vs 2-field | ~67% more map entries to copy | 1 (put only) |

The Env struct has 4 fields (`evidence`, `state`, `leave_scope`,
`transform_suspend`) → 5-entry backing map including `__struct__`.
The benchmark's S9 struct has 2 fields → 3-entry backing map. Every
`put_state` copies the full struct, so S10 copies ~67% more data per
state mutation.

### Per-run overhead (amortised setup/teardown)

| Source | Work |
|--------|------|
| `Env.new()` | struct + 2 anonymous fn allocations (`leave_scope`, `transform_suspend`) |
| 2× `scoped/2` setup | 6 closure allocations + 4 struct updates + 4 map operations |
| 2× `scoped/2` teardown | 2 `call_k` catch frames + 2 `finally_k` calls + 4 struct updates + 2 `Map.delete` + 2 `%Throw{}` pattern matches |
| `FiberPool.Main.drain_pending` | `Map.get` + `PendingWork.new()` alloc + destructure + 3 comparisons + `await_suspend?` pattern match |
| `ISentinel.run/2` | protocol dispatch + `leave_scope` chain call |
| `State.with_handler` opts | 2× `then/2` + 3× `Keyword.get` (all no-ops) |

At N=10 000 the per-run overhead is amortised to ~0.003 us/op. It is
measurable at small N but negligible in the benchmark.

### Where the 1.40x comes from

The dominant per-iteration cost is **~4 extra function call frames**
from `Env.get_state!`, `Env.put_state`, and `Change.new` wrappers,
plus the **larger struct copy** on every state mutation. These compound
across 10 000 iterations.

## Optimisation opportunities

### Low-hanging fruit: `@compile {:inline, ...}`

The wrapper functions `Env.get_state!/2`, `Env.put_state/3`,
`Change.new/2`, and `State.state_key/1` are small functions that add
function-call overhead on the hot path. Inlining them with
`@compile {:inline, ...}` would eliminate ~4 function calls per loop
iteration.

**Expected impact**: could close a meaningful fraction of the 1.40x
full-Skuld gap. Easy to implement and benchmark.

### Medium effort: reduce Env struct size

Move `leave_scope` and `transform_suspend` out of the `%Env{}` struct
fields and into the `state` map (trading a struct field for a map
lookup). This would reduce `%Env{}` from 4 fields to 2, making every
struct copy cheaper.

**Trade-off**: `leave_scope` and `transform_suspend` are accessed on
scope entry/exit (infrequent) but the struct is copied on every state
mutation (frequent). The trade favours fewer fields.

### Medium effort: combine scoped layers

`State.with_handler` currently creates two `scoped/2` layers
(`with_scoped_state` + `with_handler`). Combining them into a single
scoped layer would halve the closure allocations and struct updates at
setup/teardown.

**Trade-off**: increases coupling between state management and handler
installation.

### Replace struct args with tagged tuples

Replace `%Get{tag: tag}` / `%Put{tag: tag, value: v}` with
`{:get, tag}` / `{:put, tag, value}`. A 2-tuple is 3 words on the
heap; a struct is a map (header + `__struct__` key + field keys +
values).

**Expected impact**: S6 added a 1.30x step. Tagged tuples might
recover 50–70% of that, bringing the step to ~1.10–1.15x.

**Trade-off**: loses pattern-match clarity in handler definitions,
loses automatic `Jason.Encoder` from `def_op`, and requires a
different serialisation path for `EffectLogger`.

### Replace `{Mod, tag}` tuple state keys

Replace `{Skuld.Effects.State, tag}` with a cons cell `[Mod | tag]`
or precompute the key at handler installation time.

**Expected impact**: S9 added a 1.16x step. A cons cell (2 words) is
slightly cheaper than a 2-tuple (3 words), but the hashing cost for
map lookup is similar. Precomputing and closing over the key would
avoid the allocation entirely.

**Trade-off**: precomputing requires restructuring handler installation
to either split handlers per-tag or pass the key through a different
path.

### Theoretical best case

If all optimisations above succeeded fully, the combined improvement
would bring the overhead from ~2.9x (vs catch baseline) down to
roughly ~1.8–2.2x. The remaining irreducible overhead would be:

- 2 additional catch frames in `bind` and `call_handler` (1.25x)
- The `scoped/2` continuation chain and leave_scope machinery
- Protocol dispatch and drain_pending (negligible at scale)

## Summary

| Category | Multiplier | Reducible? |
|----------|-----------|------------|
| First catch frame | 2.26x | No — BEAM tax, not Skuld-specific |
| Additional catches (×2) | 1.25x | Partially — could merge `call`/`call_handler` |
| Struct args (`%Get{}`/`%Put{}`) | 1.30x | Yes — tagged tuples |
| Change struct + accessors + tuple keys | 1.23x | Partially — inlining, precomputed keys |
| Full-Skuld machinery | 1.40x | Partially — inlining, smaller Env, combined scoped |

**Skuld's actual overhead vs catch-baseline code: ~2.9x.** With the
low-hanging-fruit optimisations (inlining), this could realistically
come down to ~2.2–2.5x. Per-effect cost of ~0.3–0.5 µs remains
negligible compared to any IO operation.

<!-- nav:footer:start -->

---

[< Reference](../reference.md) | [Index](../../README.md)
<!-- nav:footer:end -->
