# Quick Reference

<!-- nav:header:start -->
[< Syntax In Depth](syntax.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Performance >](performance.md)
<!-- nav:header:end -->

## `comp` syntax

```
comp do
  x <- effect()            # effectful bind
  {:ok, y} = expr          # pure pattern match
  z = expr                 # pure assignment
end
```

## Handler installation

```elixir
comp |> Eff1.with_handler(args) |> Eff2.with_handler(args) |> Comp.run!()
```

Handler order is independent. `EffectLogger` must be innermost.

## Effect overview

### State & Environment

| Effect | Operations | Handler |
|--------|-----------|---------|
| State | `get/0,1`, `put/1,2`, `modify/1,2`, `gets/1,2` | `State.with_handler(comp, initial, opts)` |
| Reader | `ask/0,1`, `asks/1,2`, `local/2,3` | `Reader.with_handler(comp, value, opts)` |
| Writer | `tell/1,2`, `peek/0,1`, `listen/1,2`, `pass/1,2`, `censor/2,3` | `Writer.with_handler(comp, initial, opts)` |

### Error & Resources

| Effect | Operations | Handler |
|--------|-----------|---------|
| Throw | `throw/1`, `catch_error/2` | `Throw.with_handler(comp)` |
| Bracket | `bracket/3`, `bracket_/3`, `finally/2` | Pure combinator |

### Value Generation

| Effect | Operations | Prod handler | Test handler |
|--------|-----------|-------------|--------------|
| Fresh | `fresh_uuid/0` | `Fresh.with_uuid7_handler()` | `Fresh.with_test_handler()` |
| Random | `random/0`, `random_int/2`, `random_element/1`, `shuffle/1` | `Random.with_handler()` | `Random.with_seed_handler(seed: N)` |

### Collections

| Combinator | `fx_map/2`, `fx_reduce/3`, `fx_each/2`, `fx_filter/2` |
|-----------|------|
| FxList | Full Yield support |
| FxFasterList | Higher perf, limited Yield |

### Concurrency

| Effect | Key ops | Handler |
|--------|---------|---------|
| FiberPool | `fiber/1`, `await/1`, `await!/1`, `await_all/1`, `scope/1,2`, `map/2` | `FiberPool.with_handler(comp)` |
| Channel | `new/1`, `put/2`, `take/1`, `close/1`, `put_async/2`, `take_async/1` | `Channel.with_handler(comp)` |
| Brook | `from_enum/1`, `map/2,3`, `filter/2,3`, `each/2`, `reduce/3`, `to_list/1` | Pure combinator |
| Parallel | `all/1`, `race/1`, `map/2` | `Parallel.with_handler(comp)` |
| AtomicState | `get/0,1`, `put/1,2`, `modify/1,2`, `cas/2,3` | `AtomicState.with_agent_handler(comp, init)` |

### Persistence

| Effect | Operations | Handler |
|--------|-----------|---------|
| Command | `execute/1` | `Command.with_handler(comp, fn)` |
| Transaction | `transact/1`, `rollback/1`, `try_transact/1` | `Transaction.Ecto.with_handler(repo)` / `Transaction.Noop.with_handler(comp)` |

### External Integration

| Module | Key functions |
|--------|-------------|
| Port | `request/3`, `request!/3`; `with_handler/2,3`, `with_test_handler/2,3`, `with_fn_handler/2,3`, `with_stateful_handler/4` |
| Port.EffectfulFacade | `defcallback`, `__key__` helpers |
| Repo | `insert/1,2`, `update/1,2`, `delete/1,2`, `get/2,3`, `get_by/2,3`, `all/1,2`, `one/1,2` + bangs |
| Adapter | `use Skuld.Adapter, contract: M, impl: I, stack: &f/1` |
| AsyncCoroutine | `run/2,3`, `run_sync/2,3`, `cancel/1,2` |

### Logging & Durability

| Module | Key functions |
|--------|-------------|
| EffectLogger | `with_logging/1,2,3`, `with_resume/3,4`, `mark_loop/1` |
| SerializableCoroutine | `new/2`, `get_log/1`, `serialize/1`, `deserialize/1` |

### Query & Batching

| Module | Key functions |
|--------|-------------|
| Query.Contract | `deffetch`, `with_executor/2,3`, `with_cached_executor/2,3`, `with_cached_executors/2` |
| QueryBlock | `query do ... end`, `defquery`, `defqueryp` |

## Running computations

| Function | Behaviour |
|----------|-----------|
| `Comp.run(comp)` | Returns `{result, env}` |
| `Comp.run!(comp)` | Raises on Throw/Suspend |

<!-- nav:footer:start -->

---

[< Syntax In Depth](syntax.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Performance >](performance.md)
<!-- nav:footer:end -->
