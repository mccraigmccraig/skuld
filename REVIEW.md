# Skuld Review: Completeness, Strengths & Weaknesses

## Overview

Skuld is an algebraic effects library using evidence-passing style with CPS (continuation-passing style). It's well-designed and comprehensive, featuring a unified fiber-based concurrency model with automatic I/O batching and streaming support.

**Version reviewed**: 0.1.17 (post Fiber-Based Streaming epic)

---

## Strengths

### 1. Excellent Architectural Foundation

- Single unified `computation` type (vs. the dual Freer/Hefty in predecessor Freyja)
- Evidence-passing gives O(1) handler lookup
- CPS enables proper control flow effects (Yield, Throw)
- Leave-scope mechanism guarantees cleanup on both normal and error paths

### 2. Comprehensive Effect Library

23 built-in effects covering most common needs:

| Category         | Effects                                     |
|------------------|---------------------------------------------|
| State management | State, Reader, Writer, AtomicState          |
| Control flow     | Throw, Yield, Bracket                       |
| Concurrency      | FiberPool, Channel, Parallel                |
| Streaming        | Stream (map, filter, merge_join, rate_limit)|
| I/O abstraction  | Port, DB, DBTransaction, ChangesetPersist   |
| Value generation | Fresh, Random                               |
| Debugging        | EffectLogger (with replay/resume)           |
| Collections      | FxList, FxFasterList                        |

### 3. Ergonomic Syntax

The `comp` macro is well-designed:

```elixir
comp do
  x <- State.get()
  y = x + 1          # Pure bindings just work
  _ <- State.put(y)
  y * 2              # Auto-lifting
catch
  State -> 0         # Handler installation
  {Throw, :err} -> recovery()  # Interception
end
```

### 4. Testability by Design

- Every effect has test handlers (deterministic, in-memory)
- Port allows pattern-matched stubs
- Fresh/Random support seeded handlers
- BatchExecutor can be mocked per-scope for testing
- Enables property-based testing of effectful code

```elixir
# Production
comp |> Port.with_handler(%{UserQueries => :direct})

# Test - deterministic stubs
comp |> Port.with_test_handler(%{
  Port.key(UserQueries, :find, %{id: 1}) => {:ok, %{name: "Alice"}}
})
```

### 5. Unified Fiber-Based Concurrency (FiberPool)

The FiberPool effect provides a clean, unified concurrency model:

- **Cooperative fibers** - lightweight, scheduler-managed execution units
- **BEAM Tasks** - parallel execution for CPU-bound or blocking work
- **Structured concurrency** - automatic cleanup via scopes
- **Fair FIFO scheduling** - deterministic, predictable execution order
- **Simpler API** than predecessor Async - fewer concepts, cleaner semantics

```elixir
comp do
  # Submit concurrent work
  h1 <- FiberPool.fiber(fetch_user(id))
  h2 <- FiberPool.task(expensive_computation())

  # Await results
  user <- FiberPool.await(h1)
  result <- FiberPool.await(h2)

  {user, result}
end
|> FiberPool.with_handler()
```

### 6. Automatic I/O Batching

The IBatchable protocol enables automatic batching of I/O operations across fibers:

```elixir
# Multiple concurrent fetches automatically batch into single IN query
comp do
  handles <- FiberPool.fiber_all(user_ids, fn id -> DB.fetch(User, id) end)
  users <- FiberPool.await_all(handles)
  users
end
|> DB.with_executors()  # Install batch executors
|> FiberPool.with_handler()
```

Key features:
- **Protocol-based** - any effect can implement IBatchable
- **Scoped executors** - different execution strategies per scope (test vs prod)
- **Wildcard matching** - `{:db_fetch, :_}` matches any schema
- **Automatic grouping** - scheduler groups suspended fibers by batch_key

### 7. Channel-Based Communication

Bounded channels with backpressure for fiber communication:

```elixir
comp do
  ch <- Channel.new(capacity: 10)

  # Producer fiber
  _ <- FiberPool.fiber(comp do
    _ <- Enum.each(1..100, fn i -> Channel.put(ch, i) end)
    Channel.close(ch)
  end)

  # Consumer - backpressure automatically applied
  _ <- Channel.each(ch, fn item -> process(item) end)
end
```

Features:
- **Bounded buffers** with configurable capacity
- **Automatic backpressure** - put suspends when full, take suspends when empty
- **Error propagation** - errors flow through channels to consumers
- **Peek support** - for merge joins without consuming

### 8. High-Level Streaming API

GenStage-like streaming without process-per-stage overhead:

```elixir
comp do
  ch <- Stream.from_enum(1..1000)

  mapped <- Stream.map(ch, fn x ->
    result <- some_effect(x)
    result * 2
  end, concurrency: 4)

  filtered <- Stream.filter(mapped, fn x -> x > 10 end)

  Stream.to_list(filtered)
end
```

Combinators include:
- `from_enum/1`, `from_function/1` - sources
- `map/3`, `filter/3` - transforms with optional concurrency
- `merge_join/3` - database-style joins on sorted streams
- `rate_limit/2` - token bucket rate limiting
- `each/2`, `to_list/1`, `run/2` - sinks

### 9. Excellent Documentation & Test Coverage

- 758 tests
- Comprehensive README with examples for all effects
- Architecture documentation
- Benchmark documentation

---

## Weaknesses

### 1. No Effect Polymorphism / MTL-Style Constraints

You can't write:

```elixir
# Hypothetical - doesn't exist
@spec my_function() :: Comp.t(result, [State, Reader])
```

The type system doesn't track which effects a computation uses. This means:

- No compile-time effect checking
- Documentation of required effects is informal
- Easy to forget to install a handler

**Mitigation**: This is a fundamental Elixir limitation (no HKT), not fixable without language changes.

### 2. Error Messages Can Be Opaque

When a handler is missing, you get:

```
** (KeyError) key :Skuld.Effects.State not found
```

Rather than a helpful "State handler not installed" message.

**Fix**: Improve `Env.get_handler/2` to raise a descriptive custom exception.

### 3. No Effect Composition / Transformer-Style Stacking

Effects don't compose automatically. You manually install each:

```elixir
comp
|> State.with_handler(0)
|> Reader.with_handler(config)
|> Throw.with_handler()
```

There's no "default stack" or automatic composition. For complex apps, this becomes verbose.

**Potential improvement**: A `Comp.with_handlers/2` that takes a list of `{effect, config}` tuples.

### 4. FiberPool System Complexity

The FiberPool system is ~2,400 lines across multiple modules:

- Fiber (~300 LOC)
- FiberPool effect (~825 LOC)
- Scheduler + State (~840 LOC)
- Batching infrastructure (~430 LOC)

The complexity is justified for the features (batching, channels, streaming) but:

- Learning curve for understanding the internals
- Debugging suspended computations requires understanding fiber state

**Mitigation**: The API surface is clean and most users don't need to understand internals. Sequential testing mode available via `with_sequential_handler/1`.

### 5. EffectLogger Cold Resume is Fragile

While EffectLogger supports serialization and cold resume, it:

- Requires all effects to be serializable (not always possible)
- Loop marks and state checkpoints are manual
- Resume from middle of computation requires exact effect log alignment

**Reality check**: This is inherently hard; the implementation is reasonable given the constraints.

### 6. Limited Integration Examples

Missing:

- Phoenix integration guide
- Ecto integration beyond basic transactions
- GenServer integration patterns
- LiveView patterns (though AsyncComputation helps)

The library is complete but the ecosystem integration story is light.

### 7. No Effect Instrumentation / Telemetry

No built-in hooks for:

- Timing effect execution
- Counting effect invocations
- OpenTelemetry integration

**Fix**: Add optional telemetry hooks in `Comp.call/3`. (Planned for M8)

---

## Completeness Assessment

### Complete

| Area                                                | Status    |
|-----------------------------------------------------|-----------|
| Core computation machinery                          | Excellent |
| State effects (State, Reader, Writer)               | Excellent |
| Error handling (Throw)                              | Excellent |
| Resource management (Bracket)                       | Excellent |
| Coroutines (Yield)                                  | Excellent |
| Concurrency (FiberPool, Parallel, AtomicState)      | Excellent |
| Channels (bounded, backpressure, error propagation) | Excellent |
| Streaming (map, filter, join, rate limit)           | Very Good |
| I/O batching (IBatchable, scoped executors)         | Excellent |
| I/O abstraction (Port, DB)                          | Good      |
| Testing support                                     | Excellent |
| Documentation                                       | Very good |

### Partial

| Area                  | Status  | Gap                                             |
|-----------------------|---------|-------------------------------------------------|
| Database integration  | Good    | Basic fetch/fetch_all batching, more ops needed |
| Logging/observability | Basic   | No telemetry, no structured logging effect      |
| Caching               | Missing | No cache effect                                 |
| HTTP client           | Missing | Would need Port wrapping                        |
| Retry/circuit breaker | Missing | Common patterns not built-in                    |

### Missing (But Possibly Out of Scope)

| Area                 | Notes                             |
|----------------------|-----------------------------------|
| Distributed effects  | No distributed state/coordination |
| Effect type tracking | Fundamental language limitation   |

---

## Recommendations

### Short-term (Polish)

1. **Better error messages** for missing handlers
2. **`Comp.with_handlers/2`** convenience function for installing multiple handlers
3. **More DB operations** - insert, update, delete with batching
4. **Integration guide** for Phoenix/Ecto/LiveView

### Medium-term (Features)

5. **Cache effect** with TTL, LRU, test handler
6. **Retry effect** with backoff strategies
7. **HTTP effect** wrapping common HTTP clients
8. **Structured logging effect** with context propagation
9. **Telemetry hooks** - optional integration points (M8 planned)

### Long-term (Research)

10. **Explore Dialyzer specs** for effect documentation (even if not enforced)
11. **Effect "bundles"** - predefined stacks for common scenarios
12. **Fiber priorities** and deterministic testing (M8 planned)

---

## Verdict

**Skuld is a mature, well-designed algebraic effects library with excellent concurrency support.** The Fiber-Based Streaming epic has significantly improved the concurrency story:

- **FiberPool** provides a cleaner, more unified model than the previous Async
- **Automatic I/O batching** solves the N+1 problem elegantly
- **Channels and Streams** enable GenStage-like patterns without process overhead

The core is solid, the effect library is comprehensive, and the testing story is excellent. The main weaknesses are around ecosystem integration and developer experience polish rather than fundamental design issues.

For building testable, composable domain logic in Elixir with sophisticated concurrency needs, it's an excellent choice. The investment in learning the effect patterns pays off in code quality and testability.

**Rating**: 8.5/10 - Production-ready with strong concurrency primitives.
