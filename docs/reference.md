# Reference

<!-- nav:header:start -->
[< How It Works](internals.md) | [Up: Under the Hood](internals.md) | [Index](../README.md)
<!-- nav:header:end -->

## Glossary

**Computation** — A function `(env, k) -> {result, env}` that describes an
effectful program. Inert until run.

**Effect** — A named capability a computation can request. Defined by
modules (e.g. `Skuld.Effects.State`). An effect operation returns a
computation that looks up its handler at runtime.

**Handler** — A function that interprets effect requests. Installed via
`with_handler(comp, args)`. Same computation, different handlers —
production vs test.

**Evidence** — The map of effect signatures to handler functions in the
environment. O(1) lookup.

**Continuation** (`k`) — "What happens next" after an effect completes.
Normal effects call `k` once. `Throw` discards `k`. `Yield` captures `k`
for later resumption.

**Bind** (`<-`) — Sequences two computations. Desugars to `Comp.bind/2`.

**Sentinel** — A special return value (`%Throw{}`, `%ExternalSuspend{}`,
`%InternalSuspend{}`, `%ForeignSuspend{}`, `%ForeignSuspensions{}`)
signalling abnormal completion. The `ISentinel` protocol dispatches
behaviour.

**ForeignSuspend** — Suspension on an external/foreign resource
(e.g., a JS Promise). Carries an opaque `payload` and a `resume`
continuation. The `ForeignResolver` protocol resolves these across
platforms.

**ForeignSuspensions** — Aggregate of all pending `ForeignSuspend`
values bundled by the FiberPool scheduler, with a `resume` closure
for batch-waking resolved fibers.

**Scope** — A handler boundary with cleanup. `Comp.scoped/2` guarantees
cleanup runs on exit or Throw, but not on Suspend.

**Auto-lifting** — Bare values in `comp` blocks are automatically wrapped
in `Comp.pure/1`.

## Effect reference

### Foundational

| Effect | Module | Operations | Handler | Test |
|--------|--------|-----------|---------|------|
| State | `Skuld.Effects.State` | `get`, `put`, `modify`, `gets` | `with_handler(comp, init)` | Same |
| Reader | `Skuld.Effects.Reader` | `ask`, `asks`, `local` | `with_handler(comp, val)` | Same |
| Writer | `Skuld.Effects.Writer` | `tell`, `peek`, `listen`, `pass`, `censor` | `with_handler(comp, [])` | Same; `output:` captures |
| Throw | `Skuld.Effects.Throw` | `throw`, `catch_error` | `with_handler(comp)` | Same |
| Bracket | `Skuld.Effects.Bracket` | `bracket`, `bracket_`, `finally` | None (combinator) | Same |
| Fresh | `Skuld.Effects.Fresh` | `fresh_uuid` | `with_uuid7_handler()` | `with_test_handler()` |
| FreshInt | `Skuld.Effects.FreshInt` | `fresh_integer` | `with_handler(comp, seed: 0)` | Same |
| Random | `Skuld.Effects.Random` | `random`, `random_int`, `random_element`, `shuffle` | `with_handler()` | `with_seed_handler(seed:)` |
| FxList | `Skuld.Effects.FxList` | `fx_map`, `fx_reduce`, `fx_each`, `fx_filter` | None (combinator) | Same |
| Command | `Skuld.Effects.Command` | `execute` | `with_handler(comp, fn)` | Swap fn |
| Transaction | `Skuld.Effects.Transaction` | `transact`, `rollback`, `try_transact` | `Ecto.with_handler(repo)` or `Noop.with_handler(comp)` | `Noop.with_handler(comp)` |

### Coroutines & Concurrency

| Effect | Module | Operations | Handler | Test |
|--------|--------|-----------|---------|------|
| Yield | `Skuld.Effects.Yield` | `yield`, `respond`, `collect`, `feed` | `with_handler(comp)` | Same |
| Coroutine | `Skuld.Coroutine` | `new`, `run/1,2`, `call/1,2`, `cancel/1,2` | Pure data wrapper | Same |
| FiberPool | `Skuld.Effects.FiberPool` | `fiber`, `await`, `await!`, `await_all`, `scope`, `map` | `with_handler(comp)` | Same |
| Channel | `Skuld.Effects.Channel` | `new`, `put`, `take`, `close`, `put_async`, `take_async` | `with_handler(comp)` | Same |
| Brook | `Skuld.Effects.Brook` | `from_enum`, `map`, `filter`, `each`, `reduce`, `to_list` | None (combinator) | Same |
| Parallel | `Skuld.Effects.Parallel` | `all`, `race`, `map` | `with_handler(comp)` | `with_sequential_handler(comp)` |
| AtomicState | `Skuld.Effects.AtomicState` | `get`, `put`, `modify`, `cas` | `with_agent_handler(comp, init)` | `with_state_handler(comp, init)` |

### Boundaries

| Module | Purpose |
|--------|---------|
| Port | Dispatch effect. `request/3`, `request!/3`. `with_handler(comp, %{mod => resolver})` |
| Port.EffectfulFacade | Typed contracts via `defcallback`. `__key__` helpers. |
| Repo | Built-in DB contract. `InMemory`, `Ecto`, `Stub` handlers. |
| Adapter | `use Skuld.Adapter, contract: M, impl: I, stack: &f/1` |
| AsyncCoroutine | Cross-process coroutines. `run/2,3`, `run_sync/2,3`, `cancel/1,2` |
| ForeignResolver | Protocol for resolving `ForeignSuspend` values across platforms. `await_resolutions/3` (continuation-passing). `Runner.run/1` for resolution loop. |

### Cross-cutting

| Module | Purpose |
|--------|---------|
| EffectLogger | `with_logging`, `with_resume`, `mark_loop`. Must be innermost handler. |
| SerializableCoroutine | Pause-serialize-resume workflows. `new`, `get_log`, `serialize`, `deserialize`. |
| Query.Contract | `deffetch`, `with_executor`, `with_cached_executor`. FiberPool dependency. |
| QueryBlock | `query do` blocks. Auto-batches independent fetches via dependency analysis. |

## Running

| Function | Behaviour |
|----------|-----------|
| `Comp.run(comp)` | Returns `{result, env}`. Suspends/throws returned as-is. |
| `Comp.run!(comp)` | Raises on Throw or Suspend. |

## Comparisons

### vs Mox/Mimic

For simple stubs, Mox and Skuld are comparable. Skuld's advantage is
stateful call chains (reads-after-writes), deep orchestration (10+
calls), and property tests — reusable in-memory handlers replace ad-hoc
per-test stubs.

### vs GenStage/Flow

Brook is lighter-weight for effectful streaming within one process.
GenStage is better for long-running production pipelines with process
isolation.

### vs Haskell effect systems

Skuld takes the evidence-passing approach and adapts it for a dynamic
language. No type-level effect rows — runtime handler stacking instead.
The single computation type with auto-lifting makes it practical without
a type system.

<!-- nav:footer:start -->

---

[< How It Works](internals.md) | [Up: Under the Hood](internals.md) | [Index](../README.md)
<!-- nav:footer:end -->
