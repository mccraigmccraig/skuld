# Skuld Review: Completeness, Strengths & Weaknesses

## Overview

Skuld is an algebraic effects library using evidence-passing style with CPS (continuation-passing style). It's well-designed and comprehensive, but there are gaps and areas for improvement.

**Version reviewed**: 0.1.17

---

## Strengths

### 1. Excellent Architectural Foundation

- Single unified `computation` type (vs. the dual Freer/Hefty in predecessor Freyja)
- Evidence-passing gives O(1) handler lookup
- CPS enables proper control flow effects (Yield, Throw)
- Leave-scope mechanism guarantees cleanup on both normal and error paths

### 2. Comprehensive Effect Library

20 built-in effects covering most common needs:

| Category         | Effects                               |
|------------------|---------------------------------------|
| State management | State, Reader, Writer, AtomicState    |
| Control flow     | Throw, Yield, Bracket                 |
| Concurrency      | Async (with scheduler), Parallel      |
| I/O abstraction  | Port, DBTransaction, ChangesetPersist |
| Value generation | Fresh, Random                         |
| Debugging        | EffectLogger (with replay/resume)     |
| Collections      | FxList, FxFasterList                  |

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
- Enables property-based testing of effectful code

```elixir
# Production
comp |> Port.with_handler(%{UserQueries => :direct})

# Test - deterministic stubs
comp |> Port.with_test_handler(%{
  Port.key(UserQueries, :find, %{id: 1}) => {:ok, %{name: "Alice"}}
})
```

### 5. Mature Async Support

The Async effect is sophisticated:

- Structured concurrency with boundaries
- Both fibers (cooperative) and tasks (parallel)
- Fair FIFO scheduler
- Timeout support
- Proper cleanup of unawaited work

### 6. Excellent Documentation & Test Coverage

- 775 tests
- Comprehensive README
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

### 4. Async Scheduler Complexity

The Async effect is ~1200 lines with a separate 440-line Scheduler.State module. The complexity is justified for the features but:

- Learning curve is steep
- Debugging suspended computations is difficult
- The interaction between fibers, tasks, boundaries, and timers has many edge cases

**Mitigation**: The `with_sequential_handler/1` provides a simpler testing mode.

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
- LiveView patterns

The library is complete but the ecosystem integration story is light.

### 7. No Effect Instrumentation / Telemetry

No built-in hooks for:

- Timing effect execution
- Counting effect invocations
- OpenTelemetry integration

**Fix**: Add optional telemetry hooks in `Comp.call/3`.

---

## Completeness Assessment

### Complete

| Area                                             | Status    |
|--------------------------------------------------|-----------|
| Core computation machinery                       | Excellent |
| State effects (State, Reader, Writer)            | Excellent |
| Error handling (Throw)                           | Excellent |
| Resource management (Bracket)                    | Excellent |
| Coroutines (Yield)                               | Excellent |
| Async/concurrency (Async, Parallel, AtomicState) | Excellent |
| I/O abstraction (Port)                           | Good      |
| Testing support                                  | Excellent |
| Documentation                                    | Very good |

### Partial

| Area                  | Status  | Gap                                        |
|-----------------------|---------|--------------------------------------------|
| Database integration  | Basic   | Only simple transaction/changeset ops      |
| Logging/observability | Basic   | No telemetry, no structured logging effect |
| Caching               | Missing | No cache effect                            |
| HTTP client           | Missing | Would need Port wrapping                   |
| Retry/circuit breaker | Missing | Common patterns not built-in               |

### Missing (But Possibly Out of Scope)

| Area                 | Notes                             |
|----------------------|-----------------------------------|
| Distributed effects  | No distributed state/coordination |
| Streaming            | No stream processing primitives   |
| Effect type tracking | Fundamental language limitation   |

---

## Recommendations

### Short-term (Polish)

1. **Better error messages** for missing handlers
2. **`Comp.with_handlers/2`** convenience function for installing multiple handlers
3. **Telemetry hooks** - optional integration points
4. **Integration guide** for Phoenix/Ecto/LiveView

### Medium-term (Features)

5. **Cache effect** with TTL, LRU, test handler
6. **Retry effect** with backoff strategies
7. **HTTP effect** wrapping common HTTP clients
8. **Structured logging effect** with context propagation

### Long-term (Research)

9. **Explore Dialyzer specs** for effect documentation (even if not enforced)
10. **Effect "bundles"** - predefined stacks for common scenarios

---

## Verdict

**Skuld is a mature, well-designed algebraic effects library.** The core is solid, the effect library is comprehensive, and the testing story is excellent. The main weaknesses are around ecosystem integration and developer experience polish rather than fundamental design issues.

For building testable, composable domain logic in Elixir, it's an excellent choice. The investment in learning the effect patterns pays off in code quality and testability.

**Rating**: 8/10 - Production-ready with room for ecosystem growth.
