# How It Works

<!-- nav:header:start -->
[< Batch Loading](recipes/batch-loading.md) | [Index](../README.md) | [Reference >](reference.md)
<!-- nav:header:end -->

This page covers Skuld's internals for contributors. You don't need to
understand this to use the library.

## Computations

A computation is a function `(env, k) -> {result, env}`:

- `env` — the environment, carrying handler evidence and state
- `k` — the continuation, a function `(value, env) -> {result, env}`
  representing "what to do next with the result"

```elixir
# The simplest computation — just calls the continuation
fn _env, k -> k.(42, _env) end
```

`Comp.pure(value)` creates this. `comp do` blocks desugar into chains of
`Comp.bind`.

## Sequencing: the monadic core

### `Comp.pure/1`

Lifts a plain value into a computation:

```elixir
def pure(value) do
  fn _env, k -> k.(value, _env) end
end
```

The computation calls the continuation with the value — no effects, no
environment changes.

### `Comp.bind/2`

The heart of effect sequencing. Takes a computation and a function that
produces the next computation:

```elixir
def bind(comp, f) do
  fn env, k ->
    call(comp, env, fn a, env2 ->
      call(f.(a), env2, k)
    end)
  end
end
```

This is the monadic bind operation:

1. Run the first computation `comp`
2. When it produces value `a`, call `f.(a)` to get the next computation
3. Run that computation with the original continuation `k`

The key insight: `bind` returns another computation *function*, not a
result. Nothing executes until someone calls the function with an
environment and continuation. The `comp` macro transforms
sequential-looking code into nested `bind` calls:

```elixir
comp do
  x <- Reader.ask()
  y <- State.get()
  x + y
end

# Expands to:
Comp.bind(Reader.ask(), fn x ->
  Comp.bind(State.get(), fn y ->
    Comp.pure(x + y)
  end)
end)
```

Each `<-` becomes a `bind` call. The bound variable becomes the
parameter to the continuation function. There's no Process dictionary or
global state — just functions calling functions.

## Evidence-passing

Handlers are stored in `env.scope.evidence` (a `ScopeEnv` struct containing
evidence, leave_scope, and transform_suspend). When an effect operation
runs, it looks up its handler via `Env.get_handler!/2`:

```elixir
def effect(sig, args) do
  fn env, k ->
    handler = Env.get_handler!(env, sig)
    # call the handler
  end
end
```

This is O(1) map lookup, not linear search. Each handler manages its own
effect independently.

## Scoped handlers

`Comp.scoped/2` creates a handler boundary with cleanup. The setup
function installs a handler and returns a `finally_k` continuation that
runs on scope exit:

```elixir
Comp.scoped(comp, fn env ->
  previous = Env.get_handler(env, sig)
  modified = Env.with_handler(env, sig, new_handler)

  finally_k = fn value, e ->
    restored = restore_handler(e, sig, previous)
    {value, restored}
  end

  {modified, finally_k}
end)
```

`finally_k` runs on both normal exit and abnormal exit (Throw). It does
NOT run on Suspend — the scope is preserved for resumption.

## ISentinel protocol

`Comp.run/1` applies `ISentinel.run/2` to the computation result:

```elixir
def run(comp) do
  {result, env} = call(comp, Env.new(), &identity_k/2)
  ISentinel.run(result, env)
end
```

Each sentinel type has its own `ISentinel` implementation:

| Sentinel | `ISentinel.run/2` |
|----------|-------------------|
| `ExternalSuspend` | Apply `transform_suspend` to decorate `data` |
| `InternalSuspend` | Invoke `FiberPool.Main.drain_pending` (scheduler) |
| `Throw` | Run `leave_scope` for cleanup |
| `Cancelled` | Run `leave_scope` |
| Plain value | Run `leave_scope` |

## `leave_scope` and `transform_suspend`

Two chains on the environment:

- **`leave_scope`** — a chain of cleanup functions. When a computation
  exits (normally or via Throw), each scoped effect's `finally_k` runs
  in order, restoring state and cleaning up resources.
- **`transform_suspend`** — a chain of decoration functions. When a
  computation yields (`ExternalSuspend`), each scoped effect can attach
  data to the `ExternalSuspend.data` field (e.g. EffectLogger attaches
  its log).

## Coroutine

`Coroutine` wraps a computation into a typed state machine. `call/1,2`
returns raw typed states; `run/1,2` adds `ISentinel.run` for standalone
use. `FiberPool` schedules coroutines cooperatively within one process.
`AsyncCoroutine` bridges them across processes.

## Writing a custom effect

1. Define the effect module with `use Skuld.Comp.DefOp`
2. Declare operations with `def_op(operation_name(args))`
3. Implement the handler as `IHandle` or inline in `with_handler`
4. Install via `Scoped/2` for state isolation

```elixir
defmodule MyApp.Effects.Counter do
  use Skuld.Comp.DefOp

  def_op increment(amount)

  @behaviour Skuld.Comp.IHandle
  def handle({@increment_op, amount}, env, k) do
    current = Env.get_state(env, @sig, 0)
    k.({:ok, current + amount}, Env.put_state(env, @sig, current + amount))
  end

  def with_handler(comp, initial \\ 0) do
    comp
    |> Comp.with_scoped_state(@sig, initial)
    |> Comp.with_handler(@sig, &handle/3)
  end
end
```

<!-- nav:footer:start -->

---

[< Batch Loading](recipes/batch-loading.md) | [Index](../README.md) | [Reference >](reference.md)
<!-- nav:footer:end -->
