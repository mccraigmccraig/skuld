# Coroutine

<!-- nav:header:start -->
[< Yield](yield.md) | [Up: Coroutines & Concurrency](yield.md) | [Index](../../README.md) | [FiberPool >](fiberpool.md)
<!-- nav:header:end -->

A Coroutine wraps a computation into a resumable fiber with typed states.
It's the primitive that `FiberPool` schedules and `AsyncCoroutine` bridges
across processes.

## Sum-type states

A coroutine is always exactly one of these states — pattern-match on the
struct name to determine what to do next:

| State | Meaning |
|-------|---------|
| `%Coroutine.Pending{}` | Ready to start |
| `%Coroutine.ExternalSuspended{}` | Suspended for external caller |
| `%Coroutine.InternalSuspended{}` | Suspended with scheduler dependency |
| `%Coroutine.Completed{}` | Finished successfully |
| `%Coroutine.Errored{}` | Finished with error |
| `%Coroutine.Cancelled{}` | Cancelled before completion |

## Two entry points: `run` vs `call`

Following `Comp.call`/`Comp.run` convention:

- **`call/1,2`** — raw step, no `ISentinel.run`. Returns typed states directly.
  For use inside the FiberPool scheduler.
- **`run/1,2`** — step + `ISentinel.run`. Applies `transform_suspend` and
  `leave_scope` before returning typed states. For standalone use.

## Lifecycle

```elixir
fiber = Coroutine.new(comp, env)        # %Pending{}

# Standalone (with ISentinel.run):
case Coroutine.run(fiber) do
  %Coroutine.ExternalSuspended{value: v}  -> # yielded, await resume
  %Coroutine.Completed{result: r}         -> # done
  %Coroutine.Errored{error: e}            -> # error
end

# Resume:
case Coroutine.run(fiber, value) do
  %Coroutine.ExternalSuspended{} -> # yielded again
  %Coroutine.Completed{result: r} -> # done
end

# Cancel:
%Coroutine.Cancelled{reason: r} = Coroutine.cancel(fiber, :timeout)
```

## Standalone example

```elixir
comp = comp do
  name <- Yield.yield(:get_name)
  {:ok, "Hello, #{name}!"}
end
|> Yield.with_handler()

fiber = Coroutine.new(comp, Env.new())

%Coroutine.ExternalSuspended{value: :get_name} = Coroutine.run(fiber)
%Coroutine.Completed{result: {:ok, "Hello, Alice!"}} = Coroutine.run(fiber, "Alice")
```

## API

| Function | Purpose |
|----------|---------|
| `Coroutine.new(comp, env)` | Create `%Pending{}` |
| `Coroutine.run/1,2` | Step + `ISentinel.run` (standalone) |
| `Coroutine.call/1,2` | Raw step, no `ISentinel.run` (FiberPool) |
| `Coroutine.cancel/1,2` | Cancel with leave_scope cleanup |
| `Coroutine.terminal?/1` | Check if in terminal state |

<!-- nav:footer:start -->

---

[< Yield](yield.md) | [Up: Coroutines & Concurrency](yield.md) | [Index](../../README.md) | [FiberPool >](fiberpool.md)
<!-- nav:footer:end -->
