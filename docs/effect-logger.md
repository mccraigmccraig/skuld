# Serializable Coroutines (EffectLogger)

EffectLogger enables **serializable coroutines** - computations that can suspend,
have their entire state serialized to JSON, be persisted to a database or sent over
the network, and later be cold-resumed from the serialized state on a completely
different machine or process. This is event sourcing for algebraic effects: every
effect invocation is logged with its result, and the log can replay a computation
to any prior point, inject new values, and continue.

This capability appears to be unique among algebraic effect libraries. Haskell
libraries like polysemy, freer-simple, Heftia, and fused-effects all offer coroutines
with live (in-memory) continuations, but continuations are closures and **cannot be
serialized**. The only comparable system is [Temporal.io](https://temporal.io), which
achieves similar replay/resume semantics for workflows - but as heavyweight
infrastructure (a server cluster and RPC-based activity dispatch), not as a composable
library primitive.

Skuld can do this because its effects are pure computations handled by explicit handler
functions, producing JSON-serializable operation structs and return values. EffectLogger
intercepts the handler layer to record a serializable log. On resume, it re-executes
the same computation source code, fast-forwarding through completed effects using
logged values, restoring state from checkpoints, and injecting the resume value at
the suspension point.

**Capabilities:**
- **Logging** - Capture a serializable record of every effect invocation and its result
- **Replay** - Re-run a computation, short-circuiting completed effects with logged values
- **Rerun** - Re-execute after code changes; completed effects replay, failed effects re-execute
- **Cold resume** - Deserialize a log, re-execute the computation, fast-forward to the suspension point, inject a new value, and continue

## Suspend, Serialize, Resume

A computation suspends at a Yield point. The effect log - a complete record of every
effect invocation and its result - is serialized to JSON, persisted (to a database,
file, message queue, etc.), and later deserialized on a potentially different process
or machine. The computation resumes from where it left off, with all prior state
restored from the log:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, Yield, EffectLogger}
alias Skuld.Effects.EffectLogger.Log

computation = comp do
  x <- State.get()
  input <- Yield.yield(x)       # suspend here, yielding current state
  _ <- State.put(x + input)
  y <- State.get()
  {x, input, y}
end

# --- Run until suspension ---
{suspended, env} = (
  computation
  |> EffectLogger.with_logging()
  |> Yield.with_handler()
  |> State.with_handler(100)
  |> Comp.run()
)

suspended.value
#=> 100  # the yielded value (current state)

# --- Serialize the log (e.g., persist to database) ---
log = EffectLogger.get_log(env) |> Log.finalize()
json = Jason.encode!(log)

# --- Later: deserialize and cold resume ---
cold_log = json |> Jason.decode!() |> Log.from_json()

{{result, _new_log}, _env2} = (
  computation                              # same source code
  |> EffectLogger.with_resume(cold_log, 50)  # inject resume value (50)
  |> Yield.with_handler()
  |> State.with_handler(999)               # ignored - state restored from checkpoint
  |> Comp.run()
)

result
#=> {100, 50, 150}
# x=100 (from log, not from the 999 handler), input=50 (resume value), y=150 (fresh)
```

What happened during cold resume:
1. `State.get()` returned `100` - **replayed from the log**, not from the handler's initial value of `999`
2. `Yield.yield(x)` - the log shows this was where the computation suspended; the resume value `50` was **injected** here instead of suspending again
3. `State.put(150)` and `State.get()` - **executed fresh**, producing the final result

The log is fully JSON-serializable. Each `EffectLogEntry` records the effect module
(`sig`), operation struct (`data`), return value (`value`), and state
(`:executed`, `:discarded`, or `:started`). During replay, `:executed` entries
short-circuit with logged values, `:discarded` entries re-execute (they represent
effects abandoned by control flow like Throw), and `:started` entries mark
suspension points.

## Loop Marking and Pruning

For long-running loop-based computations (like LLM conversation loops), the log can
grow unboundedly. Use `mark_loop/1` to mark iteration boundaries - pruning is enabled
by default and happens eagerly after each mark, keeping memory bounded. Each mark
also captures a state checkpoint (`EnvStateSnapshot`) for cold resume:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, Writer, EffectLogger}

# Define a recursive computation that processes items
defmodule ProcessLoop do
  use Skuld.Syntax
  alias Skuld.Effects.{State, Writer, EffectLogger}

  defcomp process(items) do
    # Mark the start of each iteration - captures current state for cold resume
    # Pruning happens immediately after this mark executes
    _ <- EffectLogger.mark_loop(ProcessLoop)

    case items do
      [] ->
        State.get()  # Return final count

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

# Pruning is enabled by default - log stays bounded during execution
ProcessLoop.process(["a", "b", "c", "d"])
|> EffectLogger.with_logging()  # prune_loops: true is the default
|> State.with_handler(0)
|> Writer.with_handler([])
|> Comp.run()
#=> {{4, %EffectLogger.Log{...}}, _env}
# Log is small - only root mark + last iteration's effects
# Memory never grew beyond O(1 iteration) during execution
```

**Key benefits:**
- **Bounded memory**: Pruning happens eagerly after each `mark_loop`, so memory stays O(current iteration) even for computations that never suspend or complete
- **Cold resume**: State checkpoints are preserved for resuming from serialized logs
- **State validation**: During replay, state consistency is validated against checkpoints

To disable pruning and keep all entries (e.g., for debugging), use `prune_loops: false`:

```elixir
# (ProcessLoop defined in previous example)
alias Skuld.Comp
alias Skuld.Effects.{State, Writer, EffectLogger}

# Keep all entries for debugging
ProcessLoop.process(["a", "b", "c", "d"])
|> EffectLogger.with_logging(prune_loops: false)
|> State.with_handler(0)
|> Writer.with_handler([])
|> Comp.run()
#=> {{4, %EffectLogger.Log{...}}, _env}
```

## Looping Conversations with Cold Resume

The first example showed a single suspend/resume cycle. For long-running computations
like LLM conversation loops, `mark_loop` combined with cold resume enables
**repeated suspend/serialize/resume cycles** where each resume produces a new log
that can be serialized for the next iteration:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, Writer, Yield, EffectLogger}
alias Skuld.Effects.EffectLogger.Log

# A conversation loop that yields for user input each iteration
defmodule Conversation do
  use Skuld.Syntax
  alias Skuld.Effects.{State, Writer, Yield, EffectLogger}

  defcomp run() do
    _ <- EffectLogger.mark_loop(ConversationLoop)
    count <- State.get()
    _ <- State.put(count + 1)

    # Yield for input, then continue
    input <- Yield.yield({:prompt, "Message #{count}:"})
    _ <- Writer.tell("User said: #{input}")

    run()  # Loop forever, yielding each iteration
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
#=> suspended.value is {:prompt, "Message 0:"}

# Serialize the log
log = EffectLogger.get_log(env) |> Log.finalize()
json = Jason.encode!(log)

# Later: cold resume with user's response - suspends at next yield
cold_log = json |> Jason.decode!() |> Log.from_json()
{suspended2, env2} =
  Conversation.run()                            # same source code
  |> EffectLogger.with_resume(cold_log, "Hello!")  # inject "Hello!" at suspension point
  |> Yield.with_handler()
  |> State.with_handler(999)                    # ignored - state restored from checkpoint
  |> Writer.with_handler([])
  |> Comp.run()
#=> suspended2.value is {:prompt, "Message 1:"}

# Serialize again for the next resume cycle...
log2 = EffectLogger.get_log(env2) |> Log.finalize()
json2 = Jason.encode!(log2)
# The log stays bounded thanks to mark_loop pruning
```

Each cold resume re-executes the computation source code, fast-forwards through
completed effects using logged values, injects the resume value at the suspension
point, and continues fresh execution until the next yield - producing a new log
for the next cycle. Loop pruning keeps the log O(current iteration) regardless
of how many cycles have occurred.

## Why This Matters

Serializable coroutines turn computations into **durable, portable values**. A
suspended computation can be:

- **Persisted to a database** and resumed hours or days later (e.g., multi-step wizards, approval workflows)
- **Sent over the network** and resumed on a different node (e.g., load balancing long-running conversations)
- **Survived across deployments** - resume after deploying new code, with `allow_divergence` handling code changes gracefully
- **Retried after failures** - rerun mode re-executes failed effects while replaying successful ones
- **Inspected and debugged** - the log is a complete, readable trace of what the computation did

This is Temporal-style durable execution as a composable library primitive, without
requiring infrastructure services, RPC, or giving up algebraic effect composition.
