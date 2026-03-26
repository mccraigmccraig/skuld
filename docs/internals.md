# How It Works

<!-- nav:header:start -->
[< Batch Data Loading](recipes/batch-loading.md) | [Index](../README.md) | [Reference >](reference.md)
<!-- nav:header:end -->

This section explains Skuld's implementation. You don't need it to use
Skuld, but it helps with debugging surprising behaviour, writing custom
effects, and contributing.

If you haven't already, read [What Are Algebraic Effects?](what.md) for
the conceptual model and [Syntax In Depth](syntax.md) for how the `comp`
macro works. This section covers what happens *underneath* those layers.

## Computations are functions

Unlike Freyja (Skuld's predecessor, which used Freer monads with
explicit data structures), Skuld represents computations directly as
functions. This eliminates intermediate allocations and provides
significant performance benefits.

A computation is a function that takes an environment and a
continuation, and returns a result paired with a (possibly modified)
environment:

```elixir
@type computation :: (env(), k() -> {result(), env()})
@type k :: (term(), env() -> {result(), env()})
```

The continuation `k` is "what to do next" - it receives the result of
this computation step and the current environment, and produces the
final result. A top-level computation starts with an identity
continuation that simply returns the result unchanged:

```elixir
identity_k = fn result, env -> {result, env} end
```

As handlers and `bind` calls wrap the computation, they build up `k`
by replacing it with a new function that may (or may not) call the
previous continuation. This is where the real power of CPS arises:
a computation transformation can construct a *new* continuation that
controls what happens *after* a particular effect has been processed.
The handler receives `k` explicitly, and decides whether to call it,
when to call it, or whether to substitute something else entirely.

### Why continuation-passing style?

CPS gives us the ability to manipulate control flow. Because each
handler receives `k` as an explicit parameter, it can:

- **Call `k` once** (normal effects) - process the effect and continue
- **Discard `k`** (Throw) - stop the computation entirely
- **Capture `k`** (Yield) - return it for later resumption
- **Wrap `k`** (Catch) - intercept errors from downstream code
- **Call `k` multiple times** (non-determinism) - fork execution

Direct-style (non-CPS) can handle the first case, but every other case
requires the ability to decide *whether*, *when*, and *how many times*
to invoke the continuation. This is what makes algebraic effects more
powerful than simple dependency injection.

### Why functions instead of data structures?

Consider what happens with 1000 sequenced effects:

**Freer monad approach** (Freyja):
- Each `bind` creates a data structure
- A queue of 1000 continuation objects accumulates
- An interpreter walks through the queue, allocating intermediate
  results

**Evidence-passing CPS** (Skuld):
- Each `bind` creates a closure (function)
- No explicit queue - continuations are nested function calls
- Execution is direct function application

The CPS approach avoids queue management overhead and intermediate
allocations. In benchmarks, Skuld is roughly 4x faster than Freyja for
effect-heavy computations.

## The environment

The environment carries everything a computation needs:

```elixir
%Skuld.Comp.Env{
  evidence: %{sig => handler_fn},
  state: %{key => value},
  leave_scope: fn result, env -> ... end,
  transform_suspend: fn suspend, env -> ... end
}
```

### Evidence: handler lookup

The `evidence` map provides O(1) handler lookup by effect signature.
Each effect module defines a unique signature (typically the module
itself):

```elixir
# In Skuld.Effects.State:
@sig __MODULE__

# When State.get() executes, it looks up @sig in env.evidence
```

This is what "evidence-passing" means: handlers are carried in the
environment as evidence that a particular effect can be handled. When
an effect operation executes, it looks up its handler by signature and
calls it directly - no searching through a list, no pattern matching
on data structures.

### State: scoped storage

The `state` map holds effect state. Keys are module-atom sigs derived
from the effect module and tag. The `sig/1` function converts tags to
CamelCase module atoms via `Module.concat`:

```elixir
# Two independent State handlers:
State.with_handler(0, tag: :counter)
State.with_handler("", tag: :name)

# Creates state keys (module-atom sigs):
# Skuld.Effects.State.Counter => 0
# Skuld.Effects.State.Name => ""
```

### leave_scope: the cleanup chain

When scoped handlers are installed, they add cleanup functions to
`leave_scope`. These compose into a chain - each handler's cleanup
runs and then delegates to the previously installed cleanup:

```elixir
# Initial: identity function
leave_scope = fn result, env -> {result, env} end

# After installing State handler with output transformation:
leave_scope = fn result, env ->
  state = get_state(env)
  transformed = output_fn.(result, state)
  old_leave_scope.(transformed, cleaned_env)
end
```

This chain is how Skuld ensures cleanup happens in the right order,
even when Throw discards the continuation.

### transform_suspend: suspend decoration

Similar to `leave_scope` but for suspending computations. When a
computation yields, this function decorates the `Suspend` struct before
returning:

```elixir
# Default: identity
transform_suspend = fn suspend, env -> {suspend, env} end

# With EffectLogger decoration:
transform_suspend = fn suspend, env ->
  log = get_log(env)
  data = suspend.data || %{}
  {%{suspend | data: Map.put(data, EffectLogger, log)}, env}
end
```

Multiple handlers can add suspend decorations. They compose into a
chain - each handler's decoration is applied in sequence when the
computation suspends.

## Sequencing: the monadic core

### `Comp.pure/1`

Lifts a plain value into a computation:

```elixir
def pure(value) do
  fn _env, k -> k.(value, _env) end
end
```

The computation calls the continuation with the value - no effects, no
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
parameter to the continuation function.

## Effect operations

### `Comp.effect/2`

Creates a computation that invokes an effect handler:

```elixir
def effect(sig, args \\ nil) do
  fn env, k ->
    handler = Env.get_handler!(env, sig)
    call_handler(handler, args, env, k)
  end
end
```

This is remarkably simple:

1. Look up the handler for this effect signature
2. Call the handler with the operation args, environment, and
   continuation
3. The handler decides what to do with `k`

### Handler function signature

Handlers have the signature: `(args, env, k) -> {result, env}`

### State: the canonical example

State is the simplest stateful effect. Operations are defined using the
`def_tagged_op` macro, which generates constructor functions that emit
compact atom/tuple operations instead of structs. The tag is folded
into the effect signature using module-atom construction, so the
handler knows which tag it serves at installation time:

```elixir
defmodule Skuld.Effects.State do
  use Skuld.Comp.DefTaggedOp

  # def_tagged_op generates constructor functions:
  #   get()        => Comp.effect(State, State.Get)        (bare atom, zero alloc)
  #   get(:counter) => Comp.effect(State.Counter, State.Counter.Get)
  #   put(42)      => Comp.effect(State, {State.Put, 42})  (2-tuple)
  def_tagged_op get()
  def_tagged_op put(value)

  # Handler is built as a closure in with_handler, closing over
  # the precomputed state_key and op atoms for the specific tag:
  def with_handler(comp, initial, opts \\ []) do
    tag = Keyword.get(opts, :tag, __MODULE__)
    state_key = sig(tag)
    get_op = get_op(tag)
    put_op = put_op(tag)

    handler = fn op, env, k ->
      case op do
        ^get_op ->
          k.(Env.get_state!(env, state_key), env)

        {^put_op, value} ->
          old = Env.get_state!(env, state_key)
          k.(%Change{old: old, new: value}, Env.put_state(env, state_key, value))
      end
    end

    Comp.with_scoped_state(comp, state_key, initial, handler: handler, sig: sig(tag))
  end
end
```

Key points:
- `get` is a bare atom op (zero allocation)
- `put` is a `{PutOp, value}` tuple (2 words)
- The tag is encoded in the sig atom (`State.Counter`), not carried
  in every operation — the handler closes over the precomputed
  `state_key` and op atoms at installation time
- Both operations always call `k` exactly once - these are normal
  (non-control) effects

## Control effects: CPS in action

This is where CPS earns its keep. What a handler does with the
continuation `k` determines the character of the effect.

### Normal effects: call `k` once

```elixir
# State.get just reads and continues
# (inside the handler closure that closes over get_op and state_key)
^get_op ->
  k.(Env.get_state!(env, state_key), env)  # Always called exactly once
```

### Throw: discard `k`

```elixir
# Throw's handler - k is NEVER called, computation stops here
{^throw_op, error} ->
  {%Comp.Throw{error: error}, env}
```

The continuation `_k` represents "what would have happened next." By
not calling it, Throw short-circuits the entire rest of the
computation. The `%Comp.Throw{}` struct is a sentinel value that tells
the runtime what happened.

### Yield: capture `k`

This is where CPS really shines:

```elixir
# Yield's handler - k is CAPTURED, not called now
def handle(%Yield{value: value}, env, k) do
  captured_resume = fn input ->
    {result, final_env} = k.(input, env)

    case result do
      %ExternalSuspend{} ->
        # Another suspend - leave_scope runs when that one resolves
        {result, final_env}
      _ ->
        # Computation finished - invoke leave_scope chain
        final_env.leave_scope.(result, final_env)
    end
  end

  {%ExternalSuspend{value: value, resume: captured_resume}, env}
end
```

When the Yield handler receives an effect:

1. It receives the current continuation `k` (everything after the
   yield point)
2. It wraps `k` in `captured_resume` which closes over `env`
3. It returns an `ExternalSuspend` struct containing the yielded value
   and `captured_resume`
4. The caller can later invoke `captured_resume.(input)` to continue
   from where the computation left off
5. On resumption, if the computation completes (rather than suspending
   again), `leave_scope` is invoked to run cleanup

### Catch: wrap `k`

`catch_error` wraps the continuation to intercept errors:

```elixir
def catch_error(comp, handler_fn) do
  fn env, k ->
    call(comp, env, fn result, env2 ->
      case result do
        %Throw{error: error} ->
          # Error occurred - run recovery instead of k
          recovery_comp = handler_fn.(error)
          call(recovery_comp, env2, k)

        _ ->
          # No error - proceed normally
          k.(result, env2)
      end
    end)
  end
end
```

The wrapped continuation checks whether the result is a `Throw`. If
yes, it calls the recovery function instead of the original
continuation. If no, it proceeds normally.

### Yield execution trace

To make this concrete, let's trace through a yield-based computation:

```elixir
comp do
  x <- Yield.yield(:first)
  y <- Yield.yield(:second)
  x + y
end
|> Yield.with_handler()
|> Comp.run()
```

Step by step:

1. `Comp.run` calls the computation with identity `k`
2. First `bind` runs `Yield.yield(:first)`
3. `yield` receives continuation `k1` which represents the rest:
   `fn input, env -> [bind(:second), then x+y]`
4. `yield` returns `{%Suspend{value: :first, resume: fn input -> k1.(input, env)}, env}`
5. `ISentinel.run` sees Suspend, applies `transform_suspend`, returns
6. Caller gets `Suspend` with `resume` function

To continue:

```elixir
{%Suspend{resume: resume}, env} = result
{next_result, next_env} = resume.(10)  # x = 10
```

7. `resume.(10)` calls `k1.(10, env)`
8. `k1` binds `x = 10`, proceeds to `Yield.yield(:second)`
9. Process repeats - new `Suspend` with `y` unbound
10. Final `resume.(20)` completes: `x + y = 30`

## Installing handlers

### `Comp.with_handler/3`

Installs a handler in the evidence map:

```elixir
def with_handler(comp, sig, handler) do
  fn env, k ->
    new_env = %{env | evidence: Map.put(env.evidence, sig, handler)}
    call(comp, new_env, k)
  end
end
```

Simple: update the evidence map, then run the computation.

### `Comp.scoped/2`

Installs a handler with setup and cleanup. This is the key mechanism
that makes Skuld's scoped handlers tractable.

**The problem**: Throw discards the continuation entirely - it never
gets called. If cleanup only happened in a wrapped continuation, Throw
would skip it.

(Yield is different: it captures the continuation for later. The
wrapped continuation *will* be called when resumed, so cleanup happens
then. Yield doesn't skip cleanup - it defers it.)

**The solution: dual cleanup paths.**

`scoped` installs cleanup in two places:

1. **Wrapped continuation** (`normal_k`): for normal completion (and
   resumed Suspends)
2. **`leave_scope` chain**: for terminal abnormal exits (Throw)

```elixir
def scoped(comp, setup) do
  fn env, outer_k ->
    previous_leave_scope = Env.get_leave_scope(env)
    {modified_env, finally_k} = setup.(env)

    # Path 1: Normal exit - run finally_k then continue to outer_k
    normal_k = fn value, inner_env ->
      {new_value, final_env} = call_k(finally_k, value, inner_env)
      restored_env = Env.with_leave_scope(final_env, previous_leave_scope)

      case new_value do
        %Throw{} ->
          # finally_k itself threw - route through leave_scope
          previous_leave_scope.(new_value, restored_env)
        _ ->
          outer_k.(new_value, restored_env)
      end
    end

    # Path 2: Abnormal exit - run finally_k during leave_scope unwinding
    my_leave_scope = fn result, inner_env ->
      {new_result, final_env} = call_k(finally_k, result, inner_env)
      previous_leave_scope.(new_result,
        Env.with_leave_scope(final_env, previous_leave_scope))
    end

    # Install my_leave_scope, run comp with normal_k
    call(comp, Env.with_leave_scope(modified_env, my_leave_scope), normal_k)
  end
end
```

**Normal completion** (comp calls its continuation):

1. `comp` produces a value and calls `normal_k`
2. `normal_k` runs `finally_k` for cleanup
3. `normal_k` restores `previous_leave_scope`
4. `normal_k` calls `outer_k` with the result

**Throw** (comp discards continuation):

1. `comp` returns `%Throw{}` without calling any continuation
2. `Comp.run` sees the sentinel and calls `ISentinel.run`
3. `ISentinel.run` invokes `env.leave_scope` (which is `my_leave_scope`)
4. `my_leave_scope` runs `finally_k` for cleanup
5. `my_leave_scope` chains to `previous_leave_scope`

**Suspend** (comp captures continuation for later):

1. `comp` returns `%Suspend{}` with `normal_k` captured inside
2. `ISentinel.run` sees Suspend, applies `transform_suspend`
3. `leave_scope` is **not** called - computation is paused, not finished
4. Later, when the caller invokes `resume.(input)`, `normal_k` runs
5. When the computation finally completes (normal or Throw), `finally_k`
   runs then

The key distinction: `leave_scope` only runs for *terminal* cases -
when the computation is truly finished and the continuation has been
discarded. Suspend is non-terminal; the continuation is captured for
later, so cleanup is deferred until the resumed computation completes.

### Reverse-order cleanup guarantee

Because each `scoped` call saves the current `leave_scope` as
`previous_leave_scope` and installs its own `my_leave_scope` that
chains to it, cleanup happens in reverse installation order:

```elixir
comp
|> A.with_handler()  # Installs leave_scope_A -> identity
|> B.with_handler()  # Installs leave_scope_B -> leave_scope_A
|> C.with_handler()  # Installs leave_scope_C -> leave_scope_B
```

On exit (normal or abnormal): `finally_C` -> `finally_B` -> `finally_A`

This matches the intuition from try/finally blocks - inner resources
clean up before outer ones.

### `with_scoped_state/4`

The common pattern for effects with mutable state:

```elixir
def with_scoped_state(comp, state_key, initial_value, opts) do
  output_fn = Keyword.get(opts, :output, fn result, _state -> result end)
  suspend_fn = Keyword.get(opts, :suspend)

  scoped(comp, fn env ->
    # Setup: install state and handler
    env_with_state = Env.put_state(env, state_key, initial_value)
    env_with_handler = Env.with_handler(env_with_state, sig, &handle/3)
    env_final = maybe_add_suspend_transform(env_with_handler, suspend_fn)

    # Cleanup function
    finally_k = fn result, final_env ->
      state = Env.get_state(final_env, state_key)
      transformed = output_fn.(result, state)
      cleaned = Env.delete_state(final_env, state_key)
      {transformed, cleaned}
    end

    {env_final, finally_k}
  end)
end
```

This sets up initial state, installs the handler, and returns a cleanup
function that transforms the result using the final state and removes
the state from the environment.

## The ISentinel protocol

`ISentinel` determines how results are finalised when a computation
completes:

```elixir
defprotocol Skuld.Comp.ISentinel do
  def run(result, env)
  def run!(value)
  def sentinel?(value)
  def get_resume(sentinel)
end
```

### Normal values (Any)

Normal values invoke the `leave_scope` chain:

```elixir
defimpl Skuld.Comp.ISentinel, for: Any do
  def run(result, env) do
    env.leave_scope.(result, env)
  end

  def run!(value), do: value
  def sentinel?(_), do: false
end
```

### Suspend

Suspends bypass `leave_scope` but apply `transform_suspend`:

```elixir
defimpl Skuld.Comp.ISentinel, for: Skuld.Comp.Suspend do
  def run(suspend, env) do
    transform = Env.get_transform_suspend(env)
    transform.(suspend, env)
  end

  def run!(%Suspend{}) do
    raise "Computation suspended unexpectedly"
  end

  def sentinel?(_), do: true
  def get_resume(%Suspend{resume: resume}), do: resume
end
```

### `Comp.run/1`

Puts it all together:

```elixir
def run(comp) do
  {result, final_env} =
    call(comp, Env.with_leave_scope(Env.new(), &identity_k/2), &identity_k/2)

  ISentinel.run(result, final_env)
end
```

1. Create fresh environment with identity `leave_scope`
2. Run computation with identity continuation
3. Use `ISentinel.run/2` to finalise:
   - **Normal values**: invoke `leave_scope` chain
   - **Suspend**: apply `transform_suspend`, bypass `leave_scope`
   - **Throw**: bypass both (error state)

## Higher-order effects

Some effects take computations as parameters. CPS handles these
naturally because computations are just functions.

### `Writer.listen/2`

Captures what a computation writes:

```elixir
def listen(tag, comp) do
  fn env, k ->
    old_log = get_log(env, tag)
    env_fresh = put_log(env, tag, [])

    call(comp, env_fresh, fn result, env2 ->
      captured_log = get_log(env2, tag)
      env_restored = put_log(env2, tag, old_log)
      k.({result, captured_log}, env_restored)
    end)
  end
end
```

The pattern: save current state, run the inner computation with fresh
state, capture what changed, restore original state, continue with the
captured data.

### `Yield.respond/2`

Handles yields within a computation by providing responses:

```elixir
def respond(comp, responder_fn) do
  fn env, k ->
    call(comp, env, fn result, env2 ->
      case result do
        %Suspend{value: value, resume: resume} ->
          response_comp = responder_fn.(value)
          call(response_comp, env2, fn response, env3 ->
            {continued, env4} = resume.(response)
            call(respond(Comp.pure(continued), responder_fn), env4, k)
          end)

        _ ->
          k.(result, env2)
      end
    end)
  end
end
```

This recursively handles yields: run the computation, if it suspends,
generate a response, resume with it, and handle any further yields.

## The `comp` macro: catch clause expansion

The [Syntax In Depth](syntax.md) section covers `comp` usage. Here's
what happens underneath for the more complex cases.

### Interception (`{Module, pattern}`)

```elixir
comp do
  x <- State.get()
  _ <- if x < 0, do: Throw.throw(:negative)
  x * 2
catch
  {Throw, :negative} -> 0
end
```

Expands to:

```elixir
Skuld.Effects.Throw.intercept(
  Comp.bind(State.get(), fn x ->
    Comp.bind(
      if(x < 0, do: Throw.throw(:negative)),
      fn _ -> Comp.pure(x * 2) end
    )
  end),
  fn __skuld_caught_value__ ->
    case __skuld_caught_value__ do
      :negative -> Comp.pure(0)
      __skuld_unhandled__ -> Skuld.Effects.Throw.throw(__skuld_unhandled__)
    end
  end
)
```

The tagged pattern `{Throw, :negative}` extracts the module (`Throw`)
and inner pattern (`:negative`). The handler function receives the
thrown value directly. Unhandled values are automatically re-thrown.

### Installation (`Module -> config`)

```elixir
comp do
  x <- State.get()
  x
catch
  State -> 0
  Reader -> %{timeout: 5000}
end
```

Expands to:

```elixir
Skuld.Effects.Reader.__handle__(
  Skuld.Effects.State.__handle__(
    Comp.bind(State.get(), fn x -> Comp.pure(x) end),
    0
  ),
  %{timeout: 5000}
)
```

First clause becomes innermost handler, last clause outermost. The
config value (right side of `->`) is passed to `__handle__/2`.

### Consecutive clause grouping

Consecutive same-module clauses are grouped into one handler:

```elixir
comp do
  computation()
catch
  {Throw, :a} -> handle_a()   # ─┐ group 1 (inner)
  {Throw, :b} -> handle_b()   # ─┘
  {Yield, :x} -> handle_x()   # ─── group 2 (middle)
  {Throw, :c} -> handle_c()   # ─── group 3 (outer)
end
```

Groups 1 and 3 are separate Throw handlers because group 2 (Yield)
breaks the sequence. This matters: a throw from the Yield handler
(group 2) would be caught by group 3, not group 1.

### Mixed interception and installation

Both forms can appear together:

```elixir
comp do
  result <- risky_operation()
  result
catch
  {Throw, :recoverable} -> :fallback   # Interception (inner)
  State -> 0                            # Installation (middle)
  Throw -> nil                          # Installation (outer)
end
```

The interception catches locally, while the installation provides the
outer handler that processes uncaught throws.

### Combined `else` and `catch`

When both are present, the semantic ordering is `catch(else(body))`:

- `else` handles pattern match failures from the body
- `catch` wraps everything, catching throws from both body *and* the
  else handler

## A complete execution trace

Let's trace a computation with multiple effects end to end:

```elixir
comp do
  config <- Reader.ask()
  count <- State.get()
  _ <- State.put(count + 1)
  {config, count}
end
|> Reader.with_handler(:my_config)
|> State.with_handler(0, output: fn r, s -> {r, {:final, s}} end)
|> Comp.run!()
```

**Handler installation** (outside-in):

1. `State.with_handler` wraps computation, adds to `leave_scope`
2. `Reader.with_handler` wraps that, installs handler

Environment after installation:

```elixir
%Env{
  evidence: %{Reader => reader_handler, State => state_handler},
  state: %{{Reader, Reader} => :my_config, {State, State} => 0},
  leave_scope: fn result, env -> # State's output transform end
}
```

**Execution** (inside-out):

1. `Comp.run!` calls outermost computation (State wrapper)
2. State wrapper sets up state, calls inner (Reader wrapper)
3. Reader wrapper installs handler, calls comp body
4. `Reader.ask()` looks up Reader handler, gets `:my_config`
5. Continuation binds `config = :my_config`
6. `State.get()` looks up State handler, reads `0`
7. Continuation binds `count = 0`
8. `State.put(1)` updates state to `1`
9. `Comp.pure({:my_config, 0})` returns result
10. `ISentinel.run` sees normal value, invokes `leave_scope`
11. `leave_scope` transforms: `({:my_config, 0}, 1)` ->
    `{{:my_config, 0}, {:final, 1}}`

Final result: `{{:my_config, 0}, {:final, 1}}`

## Performance

### What the overhead looks like

Each effect invocation involves:

- Handler lookup: O(1) map access by atom key
- Closure creation for the continuation
- Function call overhead

Operations use compact representations — bare atoms for 0-arg ops,
small tuples for ops with args. No struct allocation on the hot path.

### Benchmarks

A loop incrementing a counter via `State.get()`/`State.put(n + 1)` at
N=1000 (run with `MIX_ENV=prod` for consolidated protocols):

| Approach                | Time    | Per-op    |
|-------------------------|---------|-----------|
| Pure tail recursion     | 21 us   | 0.021 us  |
| Simple state monad      | 17 us   | 0.017 us  |
| Evidence-passing (flat) | 32 us   | 0.032 us  |
| Evidence-passing + CPS  | 32 us   | 0.032 us  |
| Skuld                   | 143 us  | 0.143 us  |
| Freyja                  | ~1000 us| ~1 us     |

### Iteration strategies

At N=1000:

| Strategy     | Time   | Per-op   | Notes                                     |
|--------------|--------|----------|-------------------------------------------|
| FxFasterList | 113 us | 0.11 us  | Fastest; no Yield/Suspend support         |
| Yield        | 144 us | 0.14 us  | Use when you need interruptible iteration |
| FxList       | 227 us | 0.23 us  | Full Yield/Suspend support                |

All three maintain constant per-operation cost as N grows.

### Protocol consolidation

**This matters.** Elixir consolidates protocols only in `:prod` mode.
In `:dev` and `:test`, protocol dispatch uses a slow dynamic lookup
(~75 us per call) instead of the compiled dispatch table used in
production (~0.01 us per call). Skuld dispatches through the
`ISentinel` protocol in `Comp.run/1`, so unconsolidated protocols add
artificial overhead that doesn't exist in production.

In real-world benchmarking (high-throughput request processing), this
caused the effectful code path to appear ~4% slower than the
non-effectful equivalent. With consolidated protocols, the difference
dropped below the noise threshold - **zero measurable overhead**.

If you're benchmarking Skuld or comparing effectful vs non-effectful
code paths, always use `MIX_ENV=prod` to get production-representative
numbers. You can also set `consolidate_protocols: true` in your
`mix.exs` project config temporarily for benchmarking in dev mode.

### Where the overhead comes from

A [progressive benchmark](../bench/overhead_progressive.exs) starts
from the flat evidence-passing CPS baseline and adds one Skuld feature
at a time, measuring the marginal cost of each. At N=1000 (median of
7 runs, `MIX_ENV=prod`):

| Step | Feature added                    | us/op | vs baseline | vs catch baseline |
|------|----------------------------------|-------|-------------|-------------------|
| S0   | evf_cps baseline                 | 0.049 | 1.0x        | —                 |
| S1   | + first catch frame (`call`)     | 0.078 | 1.6x        | 1.0x              |
| S2   | + catch in `bind`                | 0.103 | 2.1x        | 1.3x              |
| S3   | + catch on handler dispatch      | 0.113 | 2.3x        | 1.4x              |
| S5   | + struct env (`%Env{}`)          | 0.113 | 2.3x        | 1.4x              |
| S10  | Full Skuld                       | 0.143 | **2.9x**    | **1.8x**          |

Three rounds of optimisation brought Skuld from ~6.7x to ~2.9x vs
the flat CPS baseline:

1. **Inlining** (`@compile {:inline, ...}`) on `Env`, `Change`, and
   `State` hot-path wrappers — eliminated function-call indirection
   overhead on the hot path
2. **Per-tag module-atom sigs** — fold the tag into the effect
   signature, eliminating redundant tag fields from operations and
   precomputing state keys at handler installation time
3. **Compact tuple ops** (`def_op`/`def_tagged_op`) — replace struct
   operation args with bare atoms (0-arg) or small tuples (N-arg),
   cutting per-operation heap allocation from ~10+ words to 0-4 words

See the
[performance investigation](research/performance-investigation.md)
for the full analysis including BEAM catch-frame mechanics.

Key findings:

1. **Almost all the overhead is catch frames** (S0→S1: **1.6x**).
   The BEAM sets up exception handling per-process; once one catch
   frame exists, additional nested catches are relatively cheap.
   Everything else Skuld adds — the struct env, handler dispatch,
   guards, accessors — contributes only **1.8x** on top of the
   catch baseline.
2. **Real-world applications already pay the catch cost.** Any code
   with `try`/`rescue`/`with` has catch frames. When porting such
   code to Skuld, the catch overhead is not new — it is already
   present. The observable overhead of adopting Skuld in a real
   application may be significantly less than the 2.9x headline
   number suggests, closer to the **1.8x** "vs catch baseline"
   column.
3. **Struct allocation was the next largest cost** — now eliminated
   by compact tuple operations (bare atoms for 0-arg ops, small tuples
   for N-arg ops).
4. **Guards, accessors, and struct env** are nearly free (1.01-1.02x).

### Key takeaways

1. **CPS overhead is minimal** — evidence-passing with CPS matches
   direct-style evidence-passing
2. **Exception handling is the largest single cost** — but it is a
   BEAM-wide tax, not Skuld-specific. Most real-world Elixir code
   already has catch frames for error handling, so this cost is
   unlikely to be observable when porting to Skuld. See "Why the
   first catch is expensive" in the
   [performance investigation](research/performance-investigation.md)
3. **Struct allocation eliminated** — compact tuple operations and
   per-tag module-atom sigs removed the struct allocation overhead
   entirely
4. **Inlining closed the full-Skuld gap** — `@compile {:inline, ...}`
   on `Env`, `Change`, and `State` wrapper functions eliminated the
   1.40x overhead from function call indirection
5. **Skuld vs Freyja**: ~7x faster
6. **Real-world perspective**: per-effect overhead of ~0.14 us is
   negligible compared to IO (database queries: 100-10000 us, HTTP
   calls: 1000-100000 us). The overhead matters only in tight loops
   with many effect calls and no IO

Run benchmarks yourself: `MIX_ENV=prod mix run bench/overhead_progressive.exs`

## Comparison with Freyja

Skuld was built after Freyja proved to have significant limitations.
Skuld's user-facing API is similar, but the implementation is
fundamentally different:

| Aspect                | Freyja                       | Skuld                |
|-----------------------|------------------------------|----------------------|
| Effect representation | Freer monad + Hefty algebras | Evidence-passing CPS |
| Computation types     | `Freer` + `Hefty`            | Single `computation` |
| Control effects       | Hefty (higher-order)         | Direct CPS           |
| Handler lookup        | Linear search through list   | O(1) map lookup      |
| Macro system          | `con` + `hefty`              | Single `comp`        |
| Performance           | ~1 us/op                     | ~0.1-0.25 us/op      |

Skuld's performance advantage comes from avoiding Freer monad object
allocation, continuation queue management, and linear handler search.

## Writing a custom effect

To create your own effect, you need:

1. **A module using `DefOp`** — the macro generates compact operation
   constructors (bare atoms for 0-arg ops, tuples for N-arg ops)
2. **A handler function** — interprets operations by pattern-matching
   on the generated op atoms
3. **A `with_handler` function** — installs the handler with
   appropriate scoping

Here's a minimal custom effect:

```elixir
defmodule MyApp.Effects.Counter do
  @moduledoc "A simple counter effect."

  use Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env

  # def_op generates constructor functions that emit compact operations:
  #   read()         => Comp.effect(Counter, Counter.Read)           (bare atom)
  #   increment(5)   => Comp.effect(Counter, {Counter.Increment, 5}) (2-tuple)
  def_op read()
  def_op increment(amount)

  # Op atom aliases for handler pattern matching
  @read_op @__read_op__
  @increment_op @__increment_op__

  # Handler - interprets operations using env.state
  def handle(@read_op, env, k) do
    k.(Env.get_state!(env, @__sig__), env)
  end

  def handle({@increment_op, amount}, env, k) do
    current = Env.get_state!(env, @__sig__)
    new_env = Env.put_state(env, @__sig__, current + amount)
    k.(current + amount, new_env)
  end

  # Install handler with scoped state
  def with_handler(comp, initial \\ 0, opts \\ []) do
    Comp.with_scoped_state(comp, @__sig__, initial,
      Keyword.merge([handler: &handle/3, sig: @__sig__], opts))
  end
end
```

Usage:

```elixir
import Skuld.Syntax

comp do
  _ <- Counter.increment(5)
  _ <- Counter.increment(3)
  Counter.read()
end
|> Counter.with_handler(0, output: fn result, count -> {result, count} end)
|> Comp.run!()
#=> {8, 8}
```

For a test handler, provide an alternative `with_handler` that uses
fixed or recorded values instead of real state.

## Resources

- [Generalized Evidence Passing for Effect Handlers](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/) -
  The academic paper that inspired Skuld's approach (Xie, Leijen, et al.)
- [Skuld source code](https://github.com/mccraigmccraig/skuld) -
  Read the actual implementation
- [Freyja](https://github.com/mccraigmccraig/freyja) - The earlier
  Freer-monad implementation, for comparison

<!-- nav:footer:start -->

---

[< Batch Data Loading](recipes/batch-loading.md) | [Index](../README.md) | [Reference >](reference.md)
<!-- nav:footer:end -->
