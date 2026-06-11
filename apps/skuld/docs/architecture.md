# Package Architecture

<!-- nav:header:start -->
[< Performance](performance.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [State, Reader & Writer >](effects/state-reader-writer.md)
<!-- nav:header:end -->

Skuld is distributed across seven independently-versioned Hex packages. This
page explains what each package provides, how they depend on each other, and
which effects live where.

## Packages

| Package | What it provides |
|---|---|
| `skuld` | Core computation engine (`Comp`), syntax macros (`Syntax`), and foundational effects including `Command` and `Transaction` |
| `skuld_concurrency` | Cooperative coroutines, the `FiberPool` scheduler, `Channel`/`Brook` streaming, and `AsyncCoroutine` process bridging |
| `skuld_port` | `Port` effect for dispatching to pluggable backends, `EffectfulFacade` for typed contracts, and `Adapter` for bridging effectful and plain code |
| `skuld_process` | `Parallel` for multi-process fan-out and `AtomicState` for process-level mutable state |
| `skuld_durable` | `SerializableCoroutine` for pause-serialize-resume workflows and `EffectLogger` for execution logging and replay |
| `skuld_query` | `Query` do-notation for auto-batching data fetches via dependency analysis and concurrent `FiberPool` dispatch (Haxl-style) |
| `skuld_repo` | Effectful Ecto Repo integration with `InMemory` (closed-world store), `Ecto` adapter, and `Stub` (stateless test double) |

## Dependency Layers

```
skuld
 ├── skuld_concurrency
 │    ├── skuld_durable
 │    └── skuld_query
 ├── skuld_port
 │    └── skuld_repo
 └── skuld_process
```

`skuld` is the sole base dependency. Every other package depends on it and
shares its module namespace (`Skuld.*`). Beyond that, packages only depend
on what they need:

- `skuld_concurrency` adds coroutines and the scheduler — everything that
  needs concurrent fibers builds on this.
- `skuld_durable` depends on `skuld_concurrency` for the coroutine
  infrastructure that `SerializableCoroutine` wraps.
- `skuld_query` depends on `skuld_concurrency` for `FiberPool`-driven
  concurrent batch dispatch.
- `skuld_port` adds the boundary abstraction. `skuld_repo` depends on it
  for the `Port`-based Repo facade.

## Effect Map

| Effect | Package |
|---|---|
| `State` | `skuld` |
| `Reader` | `skuld` |
| `Writer` | `skuld` |
| `Throw` | `skuld` |
| `Bracket` | `skuld` |
| `Fresh` | `skuld` |
| `Random` | `skuld` |
| `FxList` / `FxFasterList` | `skuld` |
| `Yield` | `skuld` |
| `Command` | `skuld` |
| `Transaction` | `skuld` |
| `Coroutine` | `skuld_concurrency` |
| `FiberPool` | `skuld_concurrency` |
| `Channel` | `skuld_concurrency` |
| `Brook` | `skuld_concurrency` |
| `AsyncCoroutine` | `skuld_concurrency` |
| `Task` | `skuld_concurrency` |
| `Port` | `skuld_port` |
| `Port.EffectfulFacade` | `skuld_port` |
| `Adapter` | `skuld_port` |
| `Parallel` | `skuld_process` |
| `AtomicState` | `skuld_process` |
| `SerializableCoroutine` | `skuld_durable` |
| `EffectLogger` | `skuld_durable` |
| `Query` / `QueryBlock` | `skuld_query` |
| `Repo` | `skuld_repo` |
| `Transaction.Ecto` | `skuld_repo` |

## Mental Model

The Skuld ecosystem is organised around the core `Comp` engine. Foundational
effects ship with the base `skuld` package; everything else is opt-in:

```
                          Comp
                     (lazy computation,
                      evidence-passing,
                      scoped handlers)
                            │
      ┌─────────────────────┼───────────────────────────┐
      │                     │                           │
 //skuld              //skuld_concurrency           //skuld_port
 //(core)                  │                      //skuld_repo
      │                     │                           │
      │                 Coroutine                ┌──────┼────┐
      │                     │                    │      │    │
 State, Reader,    ┌────────┼─────────┐          │      │  Port
 Writer, Throw,    │        │         │          │      │  Port.EffectfulFacade
 Bracket, Fresh,   │  Serializable-   │          │      │  Repo
 Random, FxList,   │   Coroutine      │          │      │
 Yield             │   (skuld_durable)│          │      │
                   │                  │          │      │
              AsyncCoroutine     FiberPool     │  Adapter
                   │                 │          │  Adapter.EffectfulContract
                   │                 ├─────────┐│
              skuld_process         │         ││
                   │                 │         ││
              Parallel         Channel    Task   ││
              AtomicState         │              ││
                                Brook            ││
                                                 ││
                                            Query.Contract
                                            QueryBlock
                                            (skuld_query:
                                             auto-batches fetches
                                             via FiberPool)
```

Start with `skuld`. It gives you the computation engine and the foundational
effects — everything you need to write pure effectful code with handler-swapping
for deterministic testing.

Add sibling packages as you need their capabilities:

- Want cooperative concurrency or streaming? Add `skuld_concurrency`.
- Calling external services behind a contract? Add `skuld_port`.
- Building durable, serialisable workflows? Add `skuld_durable`.
- Eliminating N+1 queries across remote APIs? Add `skuld_query`.
- Using Ecto and want InMemory test doubles? Add `skuld_repo`.
- Fanning work out across processes? Add `skuld_process`.

Each package is opt-in. A simple computation that only uses `State` and
`Reader` needs nothing beyond `skuld`.

<!-- nav:footer:start -->

---

[< Performance](performance.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [State, Reader & Writer >](effects/state-reader-writer.md)
<!-- nav:footer:end -->
