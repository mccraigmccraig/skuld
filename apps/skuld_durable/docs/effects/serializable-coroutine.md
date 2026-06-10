# SerializableCoroutine

<!-- nav:header:start -->
[< EffectLogger & SerializableCoroutine](effectlogger.md) | [Up: Effects](effectlogger.md) | [Index](effectlogger.md) | [Durable Computation >](../../../skuld/docs/recipes/durable-computation.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Pause-serialize-resume support for durable workflows. Wraps a coroutine
with `EffectLogger` installed innermost so every effect invocation is
captured in a JSON-serializable log.

## Building a durable coroutine

```elixir
alias Skuld.SerializableCoroutine

sc = SerializableCoroutine.new(MyWizard.run(), fn comp ->
  comp |> State.with_handler(%{}) |> Yield.with_handler() |> Throw.with_handler()
end)
```

`new/2` takes your computation and a function that installs your application
handlers. `EffectLogger` is installed *inside* your handlers so it intercepts
every effect call without you wiring it explicitly.

## Running

`run` dispatches on the input type:

```elixir
# Fresh start — runs until first Yield, returns %ExternalSuspended{}
suspended = SerializableCoroutine.run(sc)

# Live resume — pass a resume value to a suspended coroutine
SerializableCoroutine.run(suspended, "Alice")

# Cold resume from a deserialised log
SerializableCoroutine.run(log, sc, "Alice")

# Cold resume from serialised JSON (deserialises then resumes)
SerializableCoroutine.run(json, sc, "Alice")
```

The cold-resume path replays all completed effects from the log, then applies
the resume value to continue where it left off.

## Serializing and deserializing

```elixir
# Extract the log from a suspended coroutine
log = SerializableCoroutine.get_log(suspended)

# Serialize to JSON for storage (database, S3, etc.)
json = SerializableCoroutine.serialize(log)

# Later: deserialize and cold-resume
{:ok, log} = SerializableCoroutine.deserialize(json)
SerializableCoroutine.run(log, sc, resume_value)
```

## How it works

1. `new/2` stores the computation and your handler-stack function.
2. `run` (fresh) installs `EffectLogger` inside your handlers, then starts
   a `Coroutine`. EffectLogger wraps every handler so each invocation is
   logged with its result.
3. When the coroutine suspends (via `Yield`), the log is accessible from
   the environment via `get_log/1`.
4. `serialize/1` finalizes the log and encodes it to JSON. `deserialize/1`
   reverses this.
5. Cold resume replays the log: `EffectLogger.with_resume/3` short-circuits
   completed effects with their logged values, then resumes the coroutine
   at the point where it left off.

<!-- nav:footer:start -->

---

[< EffectLogger & SerializableCoroutine](effectlogger.md) | [Up: Effects](effectlogger.md) | [Index](effectlogger.md) | [Durable Computation >](../../../skuld/docs/recipes/durable-computation.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
