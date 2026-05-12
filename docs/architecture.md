# Architecture

<!-- nav:header:start -->
[< Quick Reference](quick-reference.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Internals >](internals.md)
<!-- nav:header:end -->

Skuld is built in layers. Each layer depends on the one below it and
provides capabilities to the one above.

## The stack

```
  ┌─────────────────────────────────────────────────────────┐
  │                    Boundaries                           │
  │  Port.EffectfulContract   Port.Facade   Query.Contract  │
  │  AsyncComputation         Command                       │
  ├─────────────────────────────────────────────────────────┤
  │              Concurrency & Streaming                    │
  │  Channel (bounded, backpressure)    Brook (streaming)   │
  ├─────────────────────────────────────────────────────────┤
  │                 FiberPool                                │
  │  Cooperative scheduler for fibers + BEAM task coord     │
  ├─────────────────────────────────────────────────────────┤
  │                   Fiber                                  │
  │  Resumable computation wrapper — sum-type lifecycle     │
  │  Pending → InternalSuspended/ExternalSuspended          │
  │         → Completed | Errored | Cancelled               │
  ├─────────────────────────────────────────────────────────┤
  │              Foundational Effects                        │
  │  State    Reader    Writer    Throw    Bracket           │
  │  Fresh    Random   FxList                             │
  ├─────────────────────────────────────────────────────────┤
  │                    Comp                                  │
  │  Lazy computation: (env, k) → {result, env}             │
  │  Evidence-passing handler dispatch   CPS for control    │
  │  Scope / leave-scope chain / scoped state               │
  └─────────────────────────────────────────────────────────┘
```

## Layer by layer

### Comp — the lazy computation

`Skuld.Comp` is the foundation. Every computation is a 2-arity function
`(env, k) -> {result, env}` that carries effect handlers in an evidence
map, maintains a leave-scope chain for cleanup on exit, and threads
mutable state through the environment. Handlers are installed via
`with_handler` and `with_scoped_state`, which save/restore on scope
entry/exit.

### Foundational Effects

These effects are built directly on Comp with no additional machinery:

| Effect | What it provides |
|--------|-----------------|
| `State` | Mutable state threaded through computation |
| `Reader` | Immutable environment value access |
| `Writer` | Append-only log accumulation |
| `Throw` | Typed error throwing and catching |
| `Bracket` | Safe resource acquire/release (try/finally) |
| `Fresh` | UUID generation with deterministic test handler |
| `Random` | Random values with seeded/fixed test handlers |
| `FxList` / `FxFasterList` | Effectful list map/reduce/filter |

These effects work independently — you can `Comp.run!()` a computation
with just `State.with_handler(0)` and `Throw.with_handler()` and have a
fully functional program. No FiberPool, no channels, no ports needed.

### Fiber — the resumable computation

`Skuld.Fiber` wraps a Comp and manages its evolving state across
incremental execution. A fiber is a sum type:

```
Pending ──run()──→ Completed | InternalSuspended | ExternalSuspended | Errored
                      ↑                  │                     │
                      │            run(value)            run(value)
                      │                  │                     │
                      └──────────────────┴─────────────────────┘
```

Fibers can suspend (when a computation yields, awaits, or blocks on a
channel), be resumed with a value, and be cancelled with cleanup. This is
the primitive that enables cooperative concurrency — but Fiber itself
has no scheduler. It just provides the state machine.

### FiberPool — the scheduler

`Skuld.Effects.FiberPool` provides cooperative scheduling of fibers within
a single BEAM process. When an `await` suspends a fiber, the scheduler
runs other fibers. When the awaited fiber completes, the awaiter is woken.
The pool also coordinates BEAM `Task` processes, tracks completion, and
detects deadlock.

### Concurrency & Streaming

`Channel` and `Brook` are built on FiberPool:

- **Channel** — bounded buffer with suspending `put`/`take`. When full,
  `put` suspends. When empty, `take` suspends. Error state is sticky and
  propagates to all waiters. Rendezvous channels (capacity 0) provide
  direct producer-consumer pairing.

- **Brook** — streaming combinator library built on Channel. Provides
  `map`, `filter`, `flat_map`, `to_list`, `each`, and `run` with optional
  concurrent transforms and automatic chunking. Error propagation flows
  downstream through the channel.

### Boundaries — interfacing with the outside world

- **`Port.EffectfulContract`** — generates typed effectful behaviours from
  `DoubleDown.Contract` declarations. Plain code (Ecto adapters, HTTP
  clients) implements the behaviour; effectful code calls through the
  facade.

- **`Port.Facade`** — single-module contract + effectful dispatch. Defines
  operations inline and generates both the contract and the effectful
  caller functions.

- **`Query.Contract`** — typed fetch contracts with automatic batching.
  `deffetch` declares operations; executors receive batches. The `query`
  macro analyses dependencies and groups independent fetches into
  concurrent fiber batches.

- **`AsyncComputation`** — bridge from Skuld effects into LiveView's
  process model. Start a computation in a separate process, receive
  messages on yield/completion, resume with user input.

- **`Command`** — fire-and-forget effect dispatch. `Command.execute(cmd)`
  delegates to a handler function installed at the handler boundary.

## Cross-cutting effects

Some effects operate at multiple layers:

| Effect | Where it operates |
|--------|------------------|
| `Yield` | Coroutine suspend/resume — works with any Comp, enables pause/resume in EffectLogger |
| `EffectLogger` | Wraps any computation, serialises effect invocation log to JSON for durable workflows |
| `Parallel` | Fork-join BEAM tasks — independent of FiberPool, works with any Comp |
| `Task` | BEAM tasks within FiberPool — bridges fiber scheduling to process parallelism |
| `Transaction` | Env state rollback + optional DB transactions via separate Noop/Ecto handlers |
| `AtomicState` | Thread-safe mutable state for concurrent contexts (Parallel, AsyncComputation) |

## Dependency summary

```
Comp
 ├── State, Reader, Writer, Throw, Bracket, Fresh, Random, FxList
 │
 ├── Fiber
 │    └── FiberPool
 │         ├── Channel
 │         │    └── Brook
 │         ├── Task
 │         └── (schedules fibers, coordinates BEAM tasks)
 │
 ├── Port
 │    ├── Port.EffectfulContract
 │    ├── Port.Facade
 │    ├── Repo (Ecto, InMemory, Stub, OpenInMemory)
 │    └── Command
 │
 ├── Yield (used by EffectLogger, AsyncComputation)
 ├── EffectLogger (wraps any computation)
 ├── Parallel (fork-join, uses Task.Supervisor)
 ├── AtomicState (Agent-backed, for Parallel/AsyncComputation contexts)
 ├── Transaction (env rollback + optional Ecto wrapping)
 └── Query.Contract / Query.QueryBlock (uses FiberPool for concurrent batching)
```

<!-- nav:footer:start -->

---

[< Quick Reference](quick-reference.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Internals >](internals.md)
<!-- nav:footer:end -->
