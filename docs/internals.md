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

## Query blocks

While `comp` do blocks are purely sequential (`Comp.bind` chains), `query`
blocks analyse variable dependencies and group independent bindings into
concurrent fiber batches via `FiberPool.fiber_await_all`:

```elixir
query do
  user   <- Users.get_user(id)
  recent <- Orders.get_recent()
  orders <- Orders.get_by_user(user.id)
  {user, recent, orders}
end

# Expands to:
FiberPool.fiber_await_all([Users.get_user(id), Orders.get_recent()])
|> Comp.bind(fn [user, recent] ->
  Comp.bind(
    Comp.bind(FiberPool.fiber(Orders.get_by_user(user.id)), &FiberPool.await!/1),
    fn orders -> {user, recent, orders} end
  )
end)
```

`get_user` and `get_recent` are independent (neither references the
other), so they're grouped into a single `fiber_await_all` — both run
concurrently as fibers. `get_by_user` depends on `user`, so it's
sequenced after the first batch completes.

The desugaring pipeline:
1. Parse bindings into `{pattern, rhs, type}` maps
2. Extract free variables from each binding's RHS
3. Build a dependency graph (which binding references which variable)
4. Topological sort into independent batches (Kahn's algorithm)
5. Emit `fiber_await_all` for batch groups, `Comp.bind` for dependencies

Because each binding runs in its own fiber, `deffetch` calls within
those bindings use `InternalSuspend.batch` — the `FiberPool` scheduler
collects them across fibers and dispatches to the executor in batches.

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
| `ForeignSuspend` | Pass through unchanged (opaque, resolved externally) |
| `ForeignSuspensions` | Pass through unchanged (aggregate of foreign suspends) |
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

## ForeignSuspend — platform-native suspension

`ForeignSuspend` is a sentinel for suspension on external resources
outside Skuld's control (e.g., JavaScript Promises, OS I/O completion
ports). Unlike `InternalSuspend` (which the FiberPool scheduler handles
itself), foreign suspends are opaque — Skuld bundles them and hands them
back to the caller for resolution.

### Lifecycle

1. A fiber raises a foreign effect (e.g., `Hologram.Skuld.Effects.JS.call`)
   → the handler creates a `%ForeignSuspend{id, resume, payload}`.
   The `payload` is an opaque handle for the foreign platform (e.g., a
   reference to a JS Promise in the browser's `NativeObjectRegistry`).
2. `Coroutine.execute_and_handle/3` detects `ForeignSuspend` and wraps it
   in `%ForeignSuspended{}` — a per-fiber state record.
3. The FiberPool scheduler collects all `ForeignSuspended` fibers into
   `%ForeignSuspensions{}` — an aggregate with a `resume` closure that
   knows how to wake all resolved fibers at once.
4. The aggregate is returned to the caller, who extracts individual
   `ForeignSuspend` values, resolves them via the foreign platform, and
   passes a `%{suspend_id => resolved_value}` map back to
   `Coroutine.call/2`.
5. The fiber resumes at its suspended point and continues executing —
   possibly hitting another foreign suspend, repeating the cycle.

### ForeignResolver protocol

`Skuld.ForeignResolver` dispatches on the `payload` type of the first
`ForeignSuspend` in the aggregate. Platform-specific implementations
resolve all suspensions and call a `continuation` function:

```elixir
defimpl Skuld.ForeignResolver, for: MyPlatform.Payload do
  def await_resolutions(_payload, suspends, continuation) do
    # Platform-specific resolution — may be sync (BEAM test) or async (JS Promise)
    resolved = Map.new(suspends, &{&1.id, resolve(&1.payload)})
    continuation.(resolved)
  end
end
```

### Runner

`Skuld.ForeignResolver.Runner.run/1` wraps a computation in a resolution
loop: run through `Comp.run`, detect `ForeignSuspensions`, call the
protocol, pass the resolved map to `Coroutine.call`, and repeat until
a `%Completed{}` result is reached.

```elixir
comp
|> FiberPool.with_handler()
|> ForeignResolver.Runner.run()
```

The Runner is platform-agnostic — the same `run/1` call works whether
the protocol impl resolves synchronously (BEAM tests) or asynchronously
(returning a JS Promise in the Hologram browser runtime).

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
