# Quick Reference

<!-- nav:header:start -->
[< Getting Started](getting-started.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Syntax Guide >](syntax.md)
<!-- nav:header:end -->

## `comp` syntax

```
comp do
  x <- effect()            # effectful bind — run effect, bind result
  {:ok, y} = expr          # pure pattern match (left of = is the pattern)
  z = expr                 # pure assignment
  return(value)            # lift value (optional — last expr is auto-lifted)
end
```

| Construct | Purpose |
|-----------|---------|
| `x <- expr` | Run effectful computation, bind result to `x` |
| `pattern = expr` | Pure Elixir pattern match |
| `return(value)` | Explicit lift (optional) |
| Last expression | Auto-lifted to `Comp.pure(value)` |
| `else` clause | Handle `<-` pattern match failures |
| `catch` clause | Intercept effects, install handlers inline |

## Handler installation

Install handlers by piping the computation through `with_handler` functions.
Order doesn't matter — each handler manages its own effect independently.

```
comp
|> Effect1.with_handler(args)
|> Effect2.with_handler(args)
|> Comp.run!()
```

Many handlers support `:output` to extract handler state:

```
|> State.with_handler(0, output: fn result, state -> {result, state} end)
```

## Effect overview

### State & Environment

| Module | Key operations | Production handler | Test handler |
|--------|---------------|-------------------|--------------|
| `Skuld.Effects.State` | `get/0`, `get/1`, `put/1`, `put/2`, `modify/1`, `modify/2`, `gets/1`, `gets/2` | `State.with_handler(comp, initial)` | (same handler — in-memory by nature) |
| `Skuld.Effects.Reader` | `ask/0`, `ask/1`, `asks/1`, `asks/2`, `local/2`, `local/3` | `Reader.with_handler(comp, value)` | (same — swap the value) |
| `Skuld.Effects.Writer` | `tell/1`, `tell/2`, `listen/1`, `listen/2`, `pass/1`, `pass/2`, `censor/2`, `censor/3`, `peek/0`, `peek/1`, `clear/0`, `clear/1` | `Writer.with_handler(comp, [], tag: :tag, output: fn r, log -> ... end)` | (same — inspect the log) |

### Concurrency

| Module | Key operations | Production handler | Test handler |
|--------|---------------|-------------------|--------------|
| `Skuld.Effects.FiberPool` | `fiber/1`, `fiber/2`, `fiber_all/1`, `await!/1`, `await_all!/1`, `await_any!/1`, `await/1`, `scope/1`, `scope/2`, `cancel/1` | `FiberPool.with_handler(comp)` | (same) |
| `Skuld.Effects.Channel` | `new/1`, `put/2`, `take/1`, `close/1`, `error/2`, `peek/1` | `Channel.with_handler(comp)` (requires FiberPool above it) | (same) |
| `Skuld.Effects.Brook` | `from_enum/1`, `from_function/1`, `map/2`, `filter/2`, `flat_map/2`, `to_list/1`, `run/1`, `each/2` | Runs within FiberPool + Channel | (same) |
| `Skuld.Effects.Parallel` | `all/1`, `race/1`, `map/2` | `Parallel.with_handler(comp)` | `Parallel.with_sequential_handler(comp)` |
| `Skuld.Effects.Task` | `task/2` | `Task.with_handler(comp)` | (same) |
| `Skuld.Effects.AtomicState` | `get/0`, `get/1`, `put/1`, `put/2`, `modify/1`, `modify/2`, `atomic_state/1`, `cas/2`, `cas/3` | `AtomicState.with_agent_handler(comp, initial, name)` | `AtomicState.with_state_handler(comp, initial)` |

### Error Handling & Control Flow

| Module | Key operations | Production handler | Test handler |
|--------|---------------|-------------------|--------------|
| `Skuld.Effects.Throw` | `throw/1`, `catch_error/2`, `intercept/2` | `Throw.with_handler(comp)` | (same — catch and inspect) |
| `Skuld.Effects.Bracket` | `bracket/3`, `finally/2` | Pure combinator, no handler | (same) |
| `Skuld.Effects.Yield` | `yield/0`, `yield/1`, `respond/2` | `Yield.with_handler(comp)` | (same) |

### Value Generation

| Module | Key operations | Production handler | Test handler |
|--------|---------------|-------------------|--------------|
| `Skuld.Effects.Fresh` | `fresh_uuid/0` | `Fresh.with_uuid7_handler(comp)` | `Fresh.with_test_handler(comp)` |
| `Skuld.Effects.Random` | `random/0`, `random_int/2`, `random_element/1`, `shuffle/1` | `Random.with_handler(comp)` (:rand) | `Random.with_seed_handler(comp)`, `Random.with_fixed_handler(comp, values)` |

### Data Access & Persistence

| Module | Key operations | Production handler | Test handler |
|--------|---------------|-------------------|--------------|
| `Skuld.Effects.Port` | `request/3`, `request!/3`, `request_bang/4` | `Port.with_handler(comp, registry)` | `Port.with_test_handler(comp, stubs)`, `Port.with_fn_handler(comp, fn)`, `Port.with_stateful_handler(comp, state, fn)` |
| `Skuld.Effects.Transaction` | `transact/1`, `rollback/1` | `Transaction.Ecto.with_handler(comp, repo)`, `Transaction.Noop.with_handler(comp)` | (same — Noop for unit, Ecto for integration) |
| `Skuld.Effects.Command` | `execute/1` | `Command.with_handler(comp, handler_fn)` | (swap the handler function) |
| `Skuld.Query.Contract` | `deffetch` macro | `Contract.with_executor(comp, executor)` | `Contract.with_executor(comp, test_executor)` |
| `Skuld.Query.QueryBlock` | `query` macro, `defquery`, `defqueryp` | Runs query blocks, auto-batches via Query.Contract | (same — swap executors) |
| `Skuld.Repo` | `insert/1,2`, `update/1,2`, `delete/1,2`, `get/2,3`, `get_by/2,3`, `all/1,2`, `one/1,2`, `aggregate/4` (+ bangs) | `Repo.Ecto` (via Port handler `%{Skuld.Repo.Effectful => ...}`) | `Repo.InMemory.with_handler(comp, state)`, `Repo.Stub.new/1` (via Port) |

### Logging & Durability

| Module | Key operations | Production handler | Test handler |
|--------|---------------|-------------------|--------------|
| `Skuld.Effects.EffectLogger` | N/A (meta-effect) | `EffectLogger.with_logging(comp)` | `EffectLogger.with_logging(comp)` (logs can be inspected) |

### Collection Iteration

| Module | Key operations | Production / test handler |
|--------|---------------|--------------------------|
| `Skuld.Effects.FxList` | `fx_map/2`, `fx_reduce/3`, `fx_each/2`, `fx_filter/2` | Pure combinators, no handler |
| `Skuld.Effects.FxFasterList` | `fx_map/2`, `fx_reduce/3`, `fx_each/2`, `fx_filter/2` | Pure combinators (higher perf, uses `Enum.reduce_while`) |

### Bridge to External Code

| Module | Key operations |
|--------|---------------|
| `Skuld.AsyncComputation` | `start/2`, `start_sync/2`, `resume/3`, `resume_sync/3`, `cancel/1`, `cancel_sync/2` |
| `Skuld.Adapter` | Macro: bring external effectful code into computations |

<!-- nav:footer:start -->

---

[< Getting Started](getting-started.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Syntax Guide >](syntax.md)
<!-- nav:footer:end -->
