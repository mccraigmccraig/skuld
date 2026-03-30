# Reference

<!-- nav:header:start -->
[< How It Works](internals.md) | [Up: Internals](internals.md) | [Index](../README.md) | [Performance Investigation >](research/performance-investigation.md)
<!-- nav:header:end -->

Quick-reference material for Skuld. For narrative explanations, start
with [Why Effects?](why.md) or [Getting Started](getting-started.md).

## Glossary

**Computation** - A function `(env, k) -> {result, env}` that
describes an effectful program. Computations are inert until run -
they don't execute side effects when constructed, only when a handler
interprets them. Created with `comp do ... end`, `Comp.pure/1`, or
effect operations like `State.get()`.

**Effect** - A named capability that a computation can request. Effects
are defined by modules (e.g., `Skuld.Effects.State`) and identified by
signatures. An effect operation returns a computation that, when
executed, looks up the appropriate handler and delegates to it.

**Handler** - A function that interprets effect requests. Handlers are
installed in the environment and looked up by effect signature. The
same computation can run with different handlers for different
behaviour (production vs test, real IO vs in-memory).

**Evidence** - The map of effect signatures to handler functions
carried in the environment. "Evidence-passing" means handlers are
threaded through computations as data, enabling O(1) lookup.

**Continuation** (`k`) - A function representing "what happens next"
after an effect operation completes. Normal effects call `k` once.
Throw discards `k`. Yield captures `k` for later resumption.

**Bind** (`<-`) - Sequences two computations. `x <- comp` runs `comp`,
extracts the result into `x`, then continues with the rest. Desugars
to `Comp.bind/2`.

**Sentinel** - A special return value (`%Throw{}`, `%Suspend{}`) that
signals abnormal completion. The `ISentinel` protocol determines how
each is finalised by `Comp.run/1`.

**Suspend** - A sentinel indicating the computation has paused (via
`Yield.yield/1`). Contains a `resume` function to continue execution
and optionally `data` decorated by handlers (e.g., EffectLogger state).

**Scope** - A handler installation boundary. Scoped handlers
(`Comp.scoped/2`) guarantee cleanup runs in reverse installation order,
whether the computation completes normally, throws, or suspends.

**`leave_scope`** - A composed cleanup chain in the environment. Each
scoped handler adds its cleanup function, chaining to the previous one.
Invoked on normal completion (via `ISentinel`) and on Throw (via
`leave_scope` unwinding). Not invoked on Suspend (deferred until
resume).

**`transform_suspend`** - A composed decoration chain in the
environment. When a computation suspends, this function decorates the
`Suspend` struct (e.g., attaching handler state for serialisation).

**Auto-lifting** - Plain values in `comp` blocks are automatically
wrapped in `Comp.pure/1`. The final expression, bare `if` without
`else`, and similar cases are lifted so you don't need explicit
`return` calls.

## Effect quick-reference

### Foundational effects

#### State & Environment

| Effect | Module | Key Operations | Handler | Test Approach |
|--------|--------|---------------|---------|---------------|
| **State** | `Skuld.Effects.State` | `get/0,1` `put/1,2` `modify/1,2` `gets/1,2` | `with_handler(comp, initial, opts)` opts: `tag:`, `output:`, `suspend:` | Use directly with initial value |
| **Reader** | `Skuld.Effects.Reader` | `ask/0,1` `asks/1,2` `local/2,3` | `with_handler(comp, value, opts)` opts: `tag:`, `output:`, `suspend:` | Use directly with test config |
| **Writer** | `Skuld.Effects.Writer` | `tell/1,2` `peek/0,1` `listen/1,2` `pass/1,2` `censor/2,3` | `with_handler(comp, initial \\ [], opts)` opts: `tag:`, `output:`, `suspend:` | Use directly; `output: &{&1, &2}` to capture log |

#### Error Handling & Resources

| Effect | Module | Key Operations | Handler | Test Approach |
|--------|--------|---------------|---------|---------------|
| **Throw** | `Skuld.Effects.Throw` | `throw/1` `catch_error/2` `try_catch/1` | `with_handler(comp)` | Use directly |
| **Bracket** | `Skuld.Effects.Bracket` | `bracket/3` `bracket_/3` `finally/2` | None needed (combinator) | Use directly |

#### Value Generation

| Effect | Module | Key Operations | Handler | Test Approach |
|--------|--------|---------------|---------|---------------|
| **Fresh** | `Skuld.Effects.Fresh` | `fresh_uuid/0` | `with_uuid7_handler(comp)` | `with_test_handler(comp, opts)` - deterministic UUID5 from namespace + counter |
| **Random** | `Skuld.Effects.Random` | `random/0` `random_int/2` `random_element/1` `shuffle/1` | `with_handler(comp)` | `with_seed_handler(comp, seed: ...)` or `with_fixed_handler(comp, values: [...])` |

#### Collections

| Effect | Module | Key Operations | Handler | Notes |
|--------|--------|---------------|---------|-------|
| **FxList** | `Skuld.Effects.FxList` | `fx_map/2` `fx_reduce/3` `fx_each/2` `fx_filter/2` | None (combinator) | Full Yield/Suspend support; ~0.2 us/op |
| **FxFasterList** | `Skuld.Effects.FxFasterList` | `fx_map/2` `fx_reduce/3` `fx_each/2` `fx_filter/2` | None (combinator) | Limited Yield support; ~0.1 us/op |

#### Concurrency

| Effect | Module | Key Operations | Handler | Test Approach |
|--------|--------|---------------|---------|---------------|
| **Parallel** | `Skuld.Effects.Parallel` | `all/1` `race/1` `map/2` | `with_handler(comp)` | `with_sequential_handler(comp)` for determinism |
| **AtomicState** | `Skuld.Effects.AtomicState` | `get/0,1` `put/1,2` `modify/1,2` `cas/2,3` `atomic_state/1,2` | `with_agent_handler(comp, initial, opts)` opts: `tag:` | `with_state_handler(comp, initial, opts)` - uses State internally |
| **AsyncComputation** | `Skuld.AsyncComputation` | `start/2` `resume/3` `cancel/1` + `_sync` variants | Not an effect; a runner module | Use `start_sync`/`resume_sync` for testing |

#### Persistence & Data

| Effect | Module | Key Operations | Handler | Test Approach |
|--------|--------|---------------|---------|---------------|
| **Transaction** | `Skuld.Effects.Transaction` | `transact/1` `rollback/1` `try_transact/1` | `Transaction.Ecto.with_handler(comp, repo, opts)` | `Transaction.Noop.with_handler(comp, opts)` - env state rollback without database |
| **Command** | `Skuld.Effects.Command` | `execute/1` | `with_handler(comp, handler_fn)` - fn receives command, returns computation | Provide test handler function |
| **EventAccumulator** | `Skuld.Effects.EventAccumulator` | `emit/1` | `with_handler(comp, opts)` opts: `output:` | `output: &{&1, &2}` to capture events |

#### External Integration

| Effect | Module | Key Operations | Handler | Test Approach |
|--------|--------|---------------|---------|---------------|
| **Port** | `Skuld.Effects.Port` | `request/3` `request!/3` | `with_handler(comp, registry, opts)` registry: `%{mod => resolver}` | `with_test_handler(comp, responses)` or `with_fn_handler(comp, fn)` |
| **Port.Contract** | `Skuld.Effects.Port.Contract` | `defport name(p :: t) :: t` | Uses Port handler | Stub via Port test handlers |
| **Port.Adapter.Effectful** | `Skuld.Effects.Port.Adapter.Effectful` | `use Port.Adapter.Effectful, contract: M, impl: I, stack: &f/1` | Bridges effectful to plain Elixir | Test the effectful impl directly |

### Advanced effects

#### Coroutines

| Effect | Module | Key Operations | Handler | Notes |
|--------|--------|---------------|---------|-------|
| **Yield** | `Skuld.Effects.Yield` | `yield/0,1` `respond/2` `collect/2` `feed/2` `run_with_driver/2` | `with_handler(comp)` | Returns `%ExternalSuspend{value, resume}` on yield |

#### Cooperative Fibers

| Effect | Module | Key Operations | Handler | Notes |
|--------|--------|---------------|---------|-------|
| **FiberPool** | `Skuld.Effects.FiberPool` | `fiber/1,2` `await/1` `await!/1` `await_all/1` `scope/1,2` `fiber_await_all/1` `map/2` | `with_handler(comp, opts)` | Cooperative scheduling within one BEAM process |
| **Channel** | `Skuld.Effects.Channel` | `new/1` `put/2` `take/1` `put_async/2` `take_async/1` `close/1` `stats/1` | `with_handler(comp)` | Bounded, backpressure. Requires FiberPool |
| **Brook** | `Skuld.Effects.Brook` | `from_enum/1,2` `from_function/1,2` `map/2,3` `filter/2,3` `each/2` `to_list/1` | None (uses Channel + FiberPool) | High-level streaming with chunking |

#### Query Batching

| Effect | Module | Key Operations | Handler | Notes |
|--------|--------|---------------|---------|-------|
| **query macro** | `Skuld.Query.QueryBlock` | `query do ... end` `defquery` `defqueryp` | Requires FiberPool | Auto-concurrent batching via dependency analysis |
| **deffetch** | `Skuld.Query.Contract` | `deffetch name(p :: t) :: t` `with_executor/2` | Executor behaviour | Fiber-based batching; executors handle `[{ref, op}]` |
| **Query.Cache** | `Skuld.Query.Cache` | `with_executors/2` `with_executor/3` | Wraps executors | Cross-batch caching + within-batch dedup |

#### Serializable Coroutines

| Effect | Module | Key Operations | Handler | Notes |
|--------|--------|---------------|---------|-------|
| **EffectLogger** | `Skuld.Effects.EffectLogger` | `mark_loop/1` | `with_logging(comp, opts)` (fresh), `with_logging(comp, log, opts)` (replay), `with_resume(comp, log, value, opts)` (cold resume) | Install before handlers it wraps (it intercepts their effects). Decorates Suspend with log. |

## Handler installation via `catch` clause

Effects that implement `IInstall` can be installed directly in `comp`
blocks using the `catch` clause:

```elixir
comp do
  x <- State.get()
  config <- Reader.ask()
  {x, config}
catch
  State -> 0                    # State.__handle__(comp, 0)
  Reader -> %{timeout: 5000}   # Reader.__handle__(comp, config)
end
```

The config value (right side of `->`) is passed to the module's
`__handle__/2` function. First clause becomes innermost handler, last
clause outermost.

Effects that implement `IIntercept` can be intercepted with tagged
patterns:

```elixir
comp do
  result <- risky_computation()
  result
catch
  {Throw, :not_found} -> :default_value
  {Yield, :checkpoint} -> :resume_value
end
```

Both forms can be mixed in a single `catch` block.

## The `output` option

Most stateful handlers accept an `output` option that transforms the
result when the computation completes:

```elixir
# Without output: result is just the computation's return value
State.with_handler(comp, 0)

# With output: result includes final state
State.with_handler(comp, 0, output: fn result, state -> {result, state} end)
```

Common patterns:

| Pattern | Output function |
|---------|----------------|
| Discard state (default) | `fn result, _state -> result end` |
| Return both | `fn result, state -> {result, state} end` |
| Return state only | `fn _result, state -> state end` |
| Transform result | `fn result, state -> apply_state(result, state) end` |

## Running computations

| Function | Behaviour |
|----------|-----------|
| `Comp.run(comp)` | Returns raw result. `%Suspend{}` and `%Throw{}` are returned as-is |
| `Comp.run!(comp)` | Returns value for normal completion. Raises on Throw or Suspend |

## Comparison with alternatives

### vs Freyja (Freer monads)

| Aspect | Freyja | Skuld |
|--------|--------|-------|
| Computation types | Two (`Freer` + `Hefty`) | One (`computation`) |
| Handler lookup | Linear search | O(1) map |
| Macro system | `con` + `hefty` | Single `comp` |
| Performance | ~1 us/op | ~0.1-0.25 us/op |
| Control effects | Hefty higher-order | Direct CPS |

Skuld is simpler (one type, one macro) and faster (~4x). Freyja's
dual type system made higher-order effects awkward.

### vs Mox/Mimic (test doubles)

| Aspect | Mox/Mimic | Skuld effects |
|--------|-----------|---------------|
| Scope | Per-process expectations | Per-computation handlers |
| Simple stubs | Clean; `stub/3` is order-independent | Clean; map or function handler |
| Stateful test doubles | Ad-hoc (Agent/closure per test) | Reusable (`Repo.InMemory` with 3-stage dispatch, `with_stateful_handler`) |
| Property testing | Possible but requires hand-rolled in-memory impls | Natural fit with reusable handlers |
| Runtime behaviour | Same code, mocked dependencies | Same code, different handlers |
| Concurrency | Per-process isolation; `allow/3` for multi-process | Handlers in computation env |

For simple cases (1-3 external calls), Mox and Skuld are comparable.
Skuld's advantage appears with stateful call chains (reads-after-writes),
deep orchestration (10+ calls), and property tests — where reusable
in-memory handlers replace ad-hoc per-test stubs. See
[Mox vs Skuld](research/MOX_VS_SKULD.md) for a detailed comparison.

### vs GenStage/Flow (streaming)

| Aspect | GenStage/Flow | Brook/Channel |
|--------|--------------|---------------|
| Concurrency model | BEAM processes | Cooperative fibers |
| Backpressure | Demand-based | Bounded channels |
| Effect integration | None | Full effect stack available |
| Testability | Requires process infrastructure | Pure handler swap |
| Overhead | Process per stage | Fibers within one process |

Brook is lighter-weight for cases where you want streaming with full
effect support. GenStage is better for long-running production
pipelines that benefit from process isolation.

### vs Temporal.io (durable workflows)

| Aspect | Temporal.io | EffectLogger |
|--------|-------------|--------------|
| Infrastructure | Separate server cluster | In-process, serialise to any store |
| Language | SDK bindings (Go, Java, etc.) | Native Elixir |
| Replay mechanism | Event sourcing on server | Log replay in computation |
| Granularity | Activity-level | Effect-level |
| Loop support | Workflow versioning | Loop marking + pruning |

EffectLogger is much lighter than Temporal but has narrower scope. It's
suitable for durable conversations, multi-step wizards, and workflows
that need to survive process restarts. It's not a distributed workflow
orchestrator.

### vs Haskell effect systems (Polysemy, Effectful, etc.)

| Aspect | Haskell libraries | Skuld |
|--------|-------------------|-------|
| Type safety | Full effect row types | Dynamic (Elixir) |
| Performance | Varies; some use delimited continuations | Evidence-passing CPS |
| Handler lookup | Type-directed | Map lookup by signature |
| Composition | Type-level effect rows | Runtime handler stacking |

Skuld takes the evidence-passing approach from [Xie & Leijen
(2021)](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/)
and adapts it for a dynamic language. The single computation type with
auto-lifting is what makes it practical without a type system - there's
no `Eff '[State, Reader, Throw] a` to track.

## Documentation map

| Layer | Document | What you'll learn |
|-------|----------|-------------------|
| 0 | [README](../README.md) | Overview, quick example, installation |
| 1 | [Why Effects?](why.md) | The problem effects solve |
| 2 | [What Are Algebraic Effects?](what.md) | The concept, no code |
| 3 | [Getting Started](getting-started.md) | First computation, handlers, running |
| 4 | [Syntax In Depth](syntax.md) | `comp` macro, `else`/`catch`, `defcomp` |
| 5 | [State & Environment](effects/state-environment.md) | State, Reader, Writer |
| 5 | [Error Handling](effects/error-handling.md) | Throw, Bracket |
| 5 | [Value Generation](effects/value-generation.md) | Fresh, Random |
| 5 | [Collections](effects/collections.md) | FxList, FxFasterList |
| 5 | [Concurrency](effects/concurrency.md) | Parallel, AtomicState, AsyncComputation |
| 5 | [Persistence](effects/persistence.md) | Transaction, Command, EventAccumulator |
| 5 | [External Integration](effects/external-integration.md) | Port, Port.Contract, Port.Adapter.Effectful |
| 6 | [Yield](advanced/yield.md) | Coroutines, suspend/resume |
| 6 | [Fibers & Concurrency](advanced/fibers-concurrency.md) | FiberPool, Channel, Brook |
| 6 | [Query Batching](advanced/query-batching.md) | query macro, deffetch, Cache |
| 6 | [EffectLogger](advanced/effect-logger.md) | Serializable coroutines, replay |
| 7 | [Testing](recipes/testing.md) | Testing patterns, property-based testing |
| 7 | [Hexagonal Architecture](recipes/hexagonal-architecture.md) | Port.Contract + Port.Adapter.Effectful |
| 7 | [Decider Pattern](recipes/decider-pattern.md) | Command + EventAccumulator |
| 7 | [Handler Stacks](recipes/handler-stacks.md) | Production vs test stacks |
| 7 | [LiveView Integration](recipes/liveview.md) | AsyncComputation in LiveView |
| 7 | [Durable Workflows](recipes/durable-workflows.md) | EffectLogger persistence |
| 7 | [Data Pipelines](recipes/data-pipelines.md) | Brook streaming |
| 7 | [Batch Loading](recipes/batch-loading.md) | Query contracts, FiberPool |
| 8 | [How It Works](internals.md) | Implementation, CPS, custom effects |
| 9 | Reference (this page) | Quick-reference tables, glossary |

<!-- nav:footer:start -->

---

[< How It Works](internals.md) | [Up: Internals](internals.md) | [Index](../README.md) | [Performance Investigation >](research/performance-investigation.md)
<!-- nav:footer:end -->
