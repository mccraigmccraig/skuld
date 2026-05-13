# Architecture

<!-- nav:header:start -->
[< Quick Reference](quick-reference.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Internals >](internals.md)
<!-- nav:header:end -->

Skuld components form a DAG rooted at `Skuld.Comp`. There are three main
branches — foundational effects, fiber concurrency, and external
boundaries — plus cross-cutting effects that work with any computation.

```
                               Comp
                            (lazy computation,
                             evidence-passing,
                             scoped handlers)
                                 │
             ┌───────────────────┼───────────────────┐
             │                   │                   │
    Foundational            Fiber /              Port /
     Effects              Concurrency           Boundaries
             │                   │                   │
   State, Reader,         Fiber               Port
   Writer, Throw,            │                   │
   Bracket, Fresh,       FiberPool ──────┐  Port.EffectfulContract
   Random, FxList            │           │  Port.Facade
                        ┌────┴────┐      │  Command
                     Channel    Task     │  Repo
                        │                │
                      Brook              │
                                         │
                                    Query.Contract
                                    QueryBlock
                                         │
                              (auto-batches fetches
                               via FiberPool fibers)
```

Most branches are independent — you can use foundational effects without
FiberPool, or Port boundaries without State or Reader. The branches
compose when you need them to: a single computation can use effects from
all three.

`Query.Contract` and `QueryBlock` are the notable inter-branch
connection: they define typed fetch contracts (Port/Boundaries style) but
use `FiberPool` fibers to batch independent fetches concurrently.

## Comp — the root

`Skuld.Comp` is the sole dependency of everything else. Every computation
is a 2-arity function `(env, k) -> {result, env}` that carries effect
handlers in an evidence map, maintains a leave-scope chain for cleanup,
and threads mutable state through the environment. Handlers are installed
via `with_handler` and `with_scoped_state`, which save/restore on scope
entry/exit.

## Foundational Effects

Built directly on Comp. These are the effects you can use in any
computation with no additional machinery — just install a handler and
`Comp.run!()`:

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

A computation with just `State.with_handler(0)` and
`Throw.with_handler()` is a fully functional program. No scheduler, no
fibers, no ports.

## Fiber / Concurrency

The cooperative concurrency branch. These components depend on Comp but
not on foundational effects or port boundaries:

### Fiber

`Skuld.Fiber` wraps a Comp and manages its evolving state across
incremental execution. A fiber is a sum type — `Pending`, `InternalSuspended`,
`ExternalSuspended`, `Completed`, `Errored`, `Cancelled`. Fibers can
suspend (yield, await, channel block), be resumed with a value, and be
cancelled with cleanup. Fiber itself has no scheduler — it just provides
the state machine.

### FiberPool

`Skuld.Effects.FiberPool` provides cooperative scheduling of fibers within
a single BEAM process. When an `await` suspends a fiber, the scheduler
runs other fibers. When the awaited fiber completes, the awaiter is woken.
The pool also coordinates BEAM `Task` processes, tracks completion, and
detects deadlock.

### Channel

Bounded buffer with suspending `put`/`take`. When full, `put` suspends.
When empty, `take` suspends. Error state is sticky and propagates to all
waiters. Rendezvous channels (capacity 0) provide direct
producer-consumer pairing. Depends on FiberPool (channels suspend fibers).

### Brook

Streaming combinator library built on Channel and FiberPool. Provides
`map`, `filter`, `to_list`, `each`, and `run` with optional concurrent
transforms and automatic chunking. Error propagation flows downstream
through channels.

### Task

BEAM task integration within FiberPool. `Task.task/2` spawns work in a
separate process; `FiberPool.await!/1` suspends until it completes.

## Port / Boundaries

These components depend on Comp (and the Port effect) but not on fibers
or foundational effects. They provide typed boundaries between effectful
and non-effectful code:

### Port

`Skuld.Effects.Port` is the dispatch effect. `Port.request(contract, name, args)`
looks up the contract in a handler registry and delegates to the
registered implementation. Handlers can be plain functions, stateful
functions, or module-based (with `DoubleDown.Contract` dispatch).

### Port.EffectfulContract

Generates typed effectful behaviours from `DoubleDown.Contract`
declarations. Plain code (Ecto adapters, HTTP clients) implements the
behaviour; effectful code calls through the facade.

### Port.Facade

Single-module contract + effectful dispatch. `use Skuld.Effects.Port.Facade`
defines operations inline and generates both the contract and the
effectful caller functions.

### Repo

Built-in Ecto Repo contract (30+ operations) dispatched through Port.
Production: `Repo.Ecto` delegates to a real Ecto Repo. Testing:
`Repo.InMemory` (stateful, authoritative), `Repo.Stub` (stateless),
`Repo.OpenInMemory` (partial authority).

### Command

Fire-and-forget effect dispatch. `Command.execute(cmd)` delegates to a
handler function installed at the handler boundary. Depends on Comp, not
on Port or FiberPool.

### Query.Contract / QueryBlock

Typed fetch contracts with automatic N+1 prevention. `deffetch` declares
operations; executors receive batches. The `query` macro analyses variable
dependencies and groups independent fetches into concurrent fiber batches.
This is the main inter-branch component — it uses Port-style typed
contracts at the contract layer and FiberPool for concurrent execution.

## Cross-cutting effects

These effects work with any computation, regardless of branch:

| Effect | What it provides | Dependencies |
|--------|-----------------|-------------|
| `Yield` | Coroutine suspend/resume | Comp only |
| `EffectLogger` | Serializable execution log for durable workflows | Comp only |
| `Parallel` | Fork-join concurrency via BEAM tasks | Comp + Task.Supervisor |
| `AtomicState` | Thread-safe mutable state | Comp + Agent |
| `Transaction` | Env state rollback + optional DB wrapping | Comp + (optional) Ecto |
| `AsyncComputation` | LiveView process bridge | Comp |

<!-- nav:footer:start -->

---

[< Quick Reference](quick-reference.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Internals >](internals.md)
<!-- nav:footer:end -->
