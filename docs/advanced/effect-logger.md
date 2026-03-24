# Serializable Coroutines (EffectLogger)

<!-- nav:header:start -->
[< Query & Batching](query-batching.md) | [Up: Advanced Effects](yield.md) | [Index](../../README.md) | [Testing Effectful Code >](../recipes/testing.md)
<!-- nav:header:end -->

EffectLogger enables **serializable coroutines** - computations that can
suspend, have their state serialized to JSON, be persisted to a database,
and later be cold-resumed from the serialized state on a different
machine or process. This is event sourcing for algebraic effects: every
effect invocation is logged with its result, and the log can replay a
computation to any prior point.

This capability appears to be unique among algebraic effect libraries.
Haskell libraries like polysemy and fused-effects offer coroutines with
live (in-memory) continuations, but continuations are closures and
**cannot be serialized**. The only comparable system is
[Temporal.io](https://temporal.io), which achieves similar replay/resume
semantics as heavyweight infrastructure (a server cluster and RPC-based
activity dispatch), not as a composable library primitive.

Skuld can do this because effects are pure computations handled by
explicit handler functions, producing JSON-serializable operation structs
and return values. EffectLogger intercepts the handler layer to record a
serializable log. On resume, it re-executes the same source code,
fast-forwarding through completed effects using logged values.

## Capabilities

- **Logging** - capture a serializable record of every effect invocation
  and its result
- **Replay** - re-run a computation, short-circuiting completed effects
  with logged values
- **Rerun** - re-execute after code changes; completed effects replay,
  failed effects re-execute
- **Cold resume** - deserialize a log, re-execute the computation,
  fast-forward to the suspension point, inject a new value, continue

## Suspend, serialize, resume

A computation suspends at a Yield point. The effect log is serialized to
JSON, persisted, and later deserialized for cold resume:

```elixir
computation = comp do
  x <- State.get()
  input <- Yield.yield(x)       # suspend here, yielding current state
  _ <- State.put(x + input)
  y <- State.get()
  {x, input, y}
end

# --- Run until suspension ---
{suspended, env} =
  computation
  |> EffectLogger.with_logging()
  |> Yield.with_handler()
  |> State.with_handler(100)
  |> Comp.run()

suspended.value
#=> 100  (the yielded value)

# --- Serialize the log ---
log = EffectLogger.get_log(env) |> Log.finalize()
json = Jason.encode!(log)

# --- Later: deserialize and cold resume ---
cold_log = json |> Jason.decode!() |> Log.from_json()

{{result, _new_log}, _env} =
  computation                                # same source code
  |> EffectLogger.with_resume(cold_log, 50)  # inject resume value
  |> Yield.with_handler()
  |> State.with_handler(999)                 # ignored - restored from log
  |> Comp.run()

result
#=> {100, 50, 150}
```

What happened during cold resume:

1. `State.get()` returned `100` - **replayed from the log**, not from
   the handler's initial value of 999
2. `Yield.yield(x)` - the log shows this was the suspension point; the
   resume value `50` was **injected** instead of suspending again
3. `State.put(150)` and `State.get()` - **executed fresh**, producing
   the final result

### Log entries

Each `EffectLogEntry` records:

- `sig` - the effect module
- `data` - the operation struct
- `value` - the return value
- State: `:executed` (completed), `:discarded` (abandoned by control
  flow), or `:started` (suspension point)

During replay: `:executed` entries short-circuit with logged values,
`:discarded` entries re-execute, `:started` entries mark where to inject
the resume value.

## Loop marking and pruning

For long-running computations (like LLM conversation loops), the log
grows unboundedly. `mark_loop/1` marks iteration boundaries. Pruning
is enabled by default and happens eagerly after each mark.

```elixir
defmodule ProcessLoop do
  use Skuld.Syntax

  defcomp process(items) do
    _ <- EffectLogger.mark_loop(ProcessLoop)

    case items do
      [] ->
        State.get()

      [item | rest] ->
        comp do
          count <- State.get()
          _ <- State.put(count + 1)
          _ <- Writer.tell("Processed: #{item}")
          process(rest)
        end
    end
  end
end

ProcessLoop.process(["a", "b", "c", "d"])
|> EffectLogger.with_logging()  # prune_loops: true is the default
|> State.with_handler(0)
|> Writer.with_handler([])
|> Comp.run()
```

Key benefits:

- **Bounded memory** - pruning happens eagerly after each `mark_loop`,
  so memory stays O(current iteration) even for infinite loops
- **Cold resume** - state checkpoints are preserved at each mark for
  resuming from serialized logs
- **State validation** - during replay, state consistency is validated
  against checkpoints

To keep all entries for debugging:

```elixir
|> EffectLogger.with_logging(prune_loops: false)
```

## Looping conversations with cold resume

For repeated suspend/serialize/resume cycles (e.g. LLM chat loops),
`mark_loop` combined with cold resume enables bounded-log multi-turn
conversations:

```elixir
defmodule Conversation do
  use Skuld.Syntax

  defcomp run() do
    _ <- EffectLogger.mark_loop(ConversationLoop)
    count <- State.get()
    _ <- State.put(count + 1)
    input <- Yield.yield({:prompt, "Message #{count}:"})
    _ <- Writer.tell("User said: #{input}")
    run()
  end
end

# First run - suspends at first yield
{suspended, env} =
  Conversation.run()
  |> EffectLogger.with_logging()
  |> Yield.with_handler()
  |> State.with_handler(0)
  |> Writer.with_handler([])
  |> Comp.run()
# suspended.value is {:prompt, "Message 0:"}

# Serialize
log = EffectLogger.get_log(env) |> Log.finalize()
json = Jason.encode!(log)

# Cold resume with user's response
cold_log = json |> Jason.decode!() |> Log.from_json()
{suspended2, env2} =
  Conversation.run()
  |> EffectLogger.with_resume(cold_log, "Hello!")
  |> Yield.with_handler()
  |> State.with_handler(999)  # ignored - restored from checkpoint
  |> Writer.with_handler([])
  |> Comp.run()
# suspended2.value is {:prompt, "Message 1:"}

# Serialize again for next cycle...
```

Each resume re-executes the source code, fast-forwards through logged
effects, injects the resume value, and continues until the next yield.
Loop pruning keeps the log O(current iteration) regardless of how many
cycles have occurred.

## Why this matters

Serializable coroutines turn computations into **durable, portable
values**. A suspended computation can be:

- **Persisted to a database** and resumed hours or days later (multi-step
  wizards, approval workflows)
- **Sent over the network** and resumed on a different node (load
  balancing long-running conversations)
- **Survived across deployments** - resume after deploying new code,
  with `allow_divergence` handling changes gracefully
- **Retried after failures** - rerun mode re-executes failed effects
  while replaying successful ones
- **Inspected and debugged** - the log is a complete, readable trace of
  what the computation did

This is Temporal-style durable execution as a composable library
primitive, without infrastructure services, RPC, or giving up algebraic
effect composition.

See [Durable Workflows](../recipes/durable-workflows.md) for practical
patterns using EffectLogger.

<!-- nav:footer:start -->

---

[< Query & Batching](query-batching.md) | [Up: Advanced Effects](yield.md) | [Index](../../README.md) | [Testing Effectful Code >](../recipes/testing.md)
<!-- nav:footer:end -->
