# Handler Stacks

<!-- nav:header:start -->
[< Property-Based Testing](property-testing.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [LiveView Integration >](liveview.md)
<!-- nav:header:end -->

Handlers compose by piping the computation through `with_handler`.
Each handler manages its own effect independently. Order mostly
doesn't matter.

## Stacking handlers

```elixir
my_computation
|> State.with_handler(0)
|> Reader.with_handler(%{env: :prod})
|> Fresh.with_uuid7_handler()
|> Port.with_handler(%{Skuld.Repo.Effectful => MyApp.Repo.Port})
|> Throw.with_handler()
|> Comp.run!()
```

## Production vs test

The same computation, different stacks:

```elixir
# Production
comp |> State.with_handler(0) |> ... |> Comp.run!()

# Test
comp |> State.with_handler(0, tag: :test) |> Repo.InMemory.with_handler(...) |> Comp.run!()
```

Swap handlers, not code.

## When order matters

The *only* time handler order is significant is when a handler wraps
other handlers. `EffectLogger` must be innermost (first in the pipe)
to record every effect invocation:

## Per-effect handler reference

| Effect | Production handler | Test handler |
|--------|-------------------|--------------|
| State | `State.with_handler(comp, init)` | Same, swap value |
| Reader | `Reader.with_handler(comp, val)` | Same, swap config |
| Writer | `Writer.with_handler(comp, [])` | Same, `output:` captures log |
| Throw | `Throw.with_handler(comp)` | Same, catch & inspect |
| Fresh | `Fresh.with_uuid7_handler()` | `Fresh.with_test_handler()` |
| Random | `Random.with_handler()` | `Random.with_seed_handler(seed: 42)` |
| Port | `Port.with_handler(comp, %{...})` | `Port.with_test_handler(stubs)` |
| Repo | `Port.with_handler(...)` via Ecto | `Repo.InMemory.with_handler(...)` |
| FiberPool | `FiberPool.with_handler(comp)` | Same |
| Channel | `Channel.with_handler(comp)` | Same |
| Transaction | `Transaction.Ecto.with_handler(repo)` | `Transaction.Noop.with_handler()` |
| EffectLogger | `EffectLogger.with_logging(comp)` | Same |

<!-- nav:footer:start -->

---

[< Property-Based Testing](property-testing.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [LiveView Integration >](liveview.md)
<!-- nav:footer:end -->
