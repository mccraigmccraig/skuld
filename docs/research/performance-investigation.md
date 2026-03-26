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

| Source                                  | Extra work                    | Count per iter |
|-----------------------------------------|-------------------------------|----------------|
| `Env.get_state!/2` wrapper fn call      | 1 function call frame         | 2 (get + put)  |
| `Env.put_state/3` wrapper fn call       | 1 function call frame         | 1 (put only)   |
| `Change.new/2` fn call vs literal       | 1 function call frame         | 1 (put only)   |
| 4-field `%Env{}` struct copy vs 2-field | ~67% more map entries to copy | 1 (put only)   |

The Env struct has 4 fields (`evidence`, `state`, `leave_scope`,
`transform_suspend`) → 5-entry backing map including `__struct__`.
The benchmark's S9 struct has 2 fields → 3-entry backing map. Every
`put_state` copies the full struct, so S10 copies ~67% more data per
state mutation.

### Per-run overhead (amortised setup/teardown)

| Source                         | Work                                                                                                             |
|--------------------------------|------------------------------------------------------------------------------------------------------------------|
| `Env.new()`                    | struct + 2 anonymous fn allocations (`leave_scope`, `transform_suspend`)                                         |
| 2× `scoped/2` setup            | 6 closure allocations + 4 struct updates + 4 map operations                                                      |
| 2× `scoped/2` teardown         | 2 `call_k` catch frames + 2 `finally_k` calls + 4 struct updates + 2 `Map.delete` + 2 `%Throw{}` pattern matches |
| `FiberPool.Main.drain_pending` | `Map.get` + `PendingWork.new()` alloc + destructure + 3 comparisons + `await_suspend?` pattern match             |
| `ISentinel.run/2`              | protocol dispatch + `leave_scope` chain call                                                                     |
| `State.with_handler` opts      | 2× `then/2` + 3× `Keyword.get` (all no-ops)                                                                      |

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

Replace `%Get{tag: tag}` / `%Put{tag: tag, value: v}` with tagged
tuples using module-style atom tags:

```elixir
# Current (struct)
Comp.effect(@sig, %Get{tag: tag})

# handler pattern match
def handle(%Get{tag: tag}, env, k) do ...
def handle(%Put{tag: tag, value: value}, env, k) do ...

# Proposed (tagged tuple with module-atom tag)
Comp.effect(@sig, {State.Get, tag})

# handler pattern match
def handle({State.Get, tag}, env, k) do ...
def handle({State.Put, tag, value}, env, k) do ...
```

Module-atom tags like `State.Get` (which is really just the atom
`Elixir.Skuld.Effects.State.Get`) give proper namespacing at zero
additional cost vs plain atoms. The `def_op` macro already knows
the module and operation name, so it can derive the tag automatically.

**Heap cost**: a 2-tuple is 3 words; a 3-tuple is 4 words. A struct
is a map (header + `__struct__` key + field keys + values) — 
considerably more. Tuple pattern matching is also faster than map
pattern matching on the BEAM (direct element comparison vs map key
lookup).

**JSON serialisation via Protocol**: the current `def_op` macro
generates `Jason.Encoder` implementations for each struct. For tagged
tuples, we can use a Protocol-based encoding mechanism:

- Define a protocol (e.g. `Skuld.Comp.OpEncoding`) for
  encoding/decoding tagged tuples to/from JSON
- `def_op` registers a protocol implementation for the specific
  module-atom tag, mapping tuple positions to named fields
- This gives straightforward JSON encoding and decoding without
  requiring structs on the hot path

The Protocol dispatch only happens in `EffectLogger` (which is
already off the hot path), so it adds no overhead to normal effect
dispatch.

**Expected impact**: S6 added a 1.30x step. Tagged tuples should
recover 50–70% of that, bringing the step to ~1.05–1.15x.

**Trade-off**: handler `def handle(...)` clauses use tuple patterns
instead of struct patterns — slightly less self-documenting, but
the module-atom tag (`State.Get`) makes the intent clear. The
`def_op` macro can generate named constructor functions to preserve
the ergonomic API (`State.get(tag)` still works unchanged).

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

### Projected impact per optimisation

The current 2.94x (vs catch baseline) is composed of multiplicative
steps. Here is what each optimisation targets and what we expect to
remain:

| Step | Feature       | Current | After opt  | What remains                                           |
|------|---------------|---------|------------|--------------------------------------------------------|
| S2   | 2nd catch     | 1.01x   | 1.01x      | Irreducible                                            |
| S3   | 3rd catch     | 1.24x   | 1.24x      | Irreducible (unless merging `call`/`call_handler`)     |
| S4   | guard         | 1.01x   | 1.01x      | Irreducible                                            |
| S5   | struct env    | 1.02x   | 1.02x      | Irreducible (still need a struct)                      |
| S6   | struct args   | 1.30x   | **~1.05–1.10x** | Tagged tuple allocation (3–4 words vs map)          |
| S7   | accessors     | 1.01x   | 1.01x      | Inlined away but underlying work remains               |
| S8   | Change struct | 1.06x   | **~1.03x** | Still return old/new pair, but lighter                 |
| S9   | tuple keys    | 1.16x   | **~1.04x** | Precomputed key eliminates per-call allocation         |
| S10  | full Skuld    | 1.40x   | **~1.15x** | `scoped` continuations, `leave_scope`, `drain_pending` |

**Optimistic projection** (all optimisations succeed well):
1.01 × 1.24 × 1.01 × 1.02 × 1.05 × 1.01 × 1.03 × 1.04 × 1.15
= **~1.67x** vs catch baseline

**Conservative projection** (partial success on each):
1.01 × 1.24 × 1.01 × 1.02 × 1.12 × 1.01 × 1.04 × 1.06 × 1.20
= **~1.87x** vs catch baseline

The **irreducible floor** — even with perfect optimisation of
everything except the catch frames — is the 1.25x from the extra
catches plus whatever the `scoped` machinery costs. That puts the
floor at roughly **~1.5x** vs catch baseline.

If we also merged the `call` and `call_handler` catch frames (bringing
1.25x down to ~1.10x), the floor drops to **~1.3–1.4x**.

### Composition of the optimised overhead

After applying all optimisations, the ~1.7–1.9x would be composed of:

| Component                            | Multiplier      | Nature                                           |
|--------------------------------------|-----------------|--------------------------------------------------|
| 2 extra catch frames                 | **1.25x**       | Irreducible (merging would be a semantic change) |
| Tagged tuple args (was struct)       | **1.05–1.10x**  | Residual heap allocation (3–4 words per op)      |
| Precomputed keys (was tuple)         | **1.03–1.06x**  | Residual map lookup cost                         |
| Scoped continuation chains           | **~1.10–1.15x** | `normal_k`, `leave_scope`, `drain_pending`       |
| Noise (guard, env struct, accessors) | **~1.05x**      | Effectively irreducible                          |

## Summary

| Category                               | Multiplier | Reducible?                                      |
|----------------------------------------|------------|-------------------------------------------------|
| First catch frame                      | 2.26x      | No — BEAM tax, not Skuld-specific               |
| Additional catches (×2)                | 1.25x      | Partially — could merge `call`/`call_handler`   |
| Struct args (`%Get{}`/`%Put{}`)        | 1.30x      | Yes — tagged tuples with module-atom tags → ~1.05–1.10x |
| Change struct + accessors + tuple keys | 1.23x      | Partially — inlining, precomputed keys → ~1.08x |
| Full-Skuld machinery                   | 1.40x      | Partially — inlining, smaller Env → ~1.15x      |

**Skuld's actual overhead vs catch-baseline code: ~2.9x.** With all
optimisations applied, this could realistically come down to
**~1.7–1.9x**. Per-effect cost would drop from ~0.3–0.5 µs to
~0.2–0.3 µs — negligible compared to any IO operation.

Tracked as epic `skuld-6ki`. The tagged-tuple spike is `skuld-wax`.

## Experiment: inlining hot-path wrappers

We added `@compile {:inline, ...}` to the hot-path wrapper functions:

- **`Skuld.Comp.Env`**: `get_state!/2`, `get_state/2`, `get_state/3`,
  `put_state/3`, `get_handler!/2`, `get_handler/2`, `with_handler/3`,
  `delete_handler/2`, `with_leave_scope/2`
- **`Skuld.Data.Change`**: `new/2`
- **`Skuld.Effects.State`**: `state_key/1`

### Results

The S9→S10 gap **completely disappeared**. Across multiple benchmark
runs at N=10000 with `MIX_ENV=prod`:

| Metric                 | Before inlining | After inlining |
|------------------------|-----------------|----------------|
| S10 (Full Skuld) us/op | 0.479           | ~0.176–0.184   |
| S10 vs S0 baseline     | 6.7x            | ~5.3–5.9x      |
| S10 vs S9 (gap)        | **1.40x**       | **~1.0x**      |

The full-Skuld step is now indistinguishable from the progressive
simulation — the function-call overhead from wrapper functions was
the entire S9→S10 gap.

Note: the individual step numbers (S1–S9) are noisier after inlining,
with the progressive benchmark's median-of-7 methodology showing
some step reordering between runs. The benchmark needs more iterations
for precise intermediate step measurements. But the headline result —
S10 ≈ S9 — is consistent across all runs.

### Impact on the overall picture

With inlining applied, the vs-catch-baseline overhead drops from
~2.9x to roughly **~2.1–2.3x** (S10/S1). The remaining overhead
is composed of:

- Additional catch frames (~1.25x)
- Struct args and Change allocation (~1.30x)
- Tuple state keys (~1.16x)
- Env struct size and scoped machinery (now negligible)

The inlining change is low-risk (all 984 tests pass) and provides a
meaningful performance improvement with zero semantic changes.

The effect is visible beyond microbenchmarks: the full test suite
(984 tests) dropped from ~0.8s to ~0.6s — a ~25% wall-clock
improvement from inlining alone.

<!-- nav:footer:start -->

---

[< Reference](../reference.md) | [Index](../../README.md)
<!-- nav:footer:end -->
