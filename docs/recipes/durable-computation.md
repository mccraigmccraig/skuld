# Durable Computation

<!-- nav:header:start -->
[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:header:end -->

Pause a computation mid-flight, save its entire execution history as
JSON, and resume it later — after a process restart, on a different
machine, whenever. Every effect invocation is recorded in a serialisable
log. Resume replays the log so the computation continues exactly where
it left off.

## The wizard

A two-step wizard that collects a name and an email:

```elixir
wizard =
  comp do
    name <- Yield.yield(:get_name)
    email <- Yield.yield(:get_email)
    {:ok, %{name: name, email: email}}
  end
```

## Build and run

Wrap the wizard with `SerializableCoroutine.new`, which installs
`EffectLogger` innermost so every effect is captured:

```elixir
sc =
  SerializableCoroutine.new(wizard, fn comp ->
    comp |> Yield.with_handler() |> Throw.with_handler()
  end)
```

Run it — it suspends at the first yield:

```elixir
%Coroutine.ExternalSuspended{value: :get_name} = suspended =
  SerializableCoroutine.run(sc)
```

Extract and inspect the log. This is the computation's complete
effect history up to the suspension point:

```elixir
log = SerializableCoroutine.get_log(suspended)
Log.to_list(log)
# => [
#   %EffectLogEntry{sig: Skuld.Effects.Yield, data: :get_name, value: nil, state: :started}
# ]
```

Serialize the log to JSON for storage and persist it:

```elixir
json = SerializableCoroutine.serialize(log)
# persist json to DB, file, or queue...
```

## Resume

Restore the log from storage and build a new coroutine with the
resume value:

```elixir
{:ok, json} = load_from_storage()
{:ok, log} = SerializableCoroutine.deserialize(json)

%Coroutine.ExternalSuspended{value: :get_email} = suspended2 =
  SerializableCoroutine.run(log, sc, "Alice")
```

Inspect the log again — it now shows the full history including the
replayed resume:

```elixir
log2 = SerializableCoroutine.get_log(suspended2)
Log.to_list(log2)
# => [
#   %EffectLogEntry{sig: Skuld.Effects.Yield, data: :get_name, value: "Alice", state: :executed},
#   %EffectLogEntry{sig: Skuld.Effects.Yield, data: :get_email, value: nil, state: :started}
# ]
```

```elixir
{:ok, json} = load_from_storage()
{:ok, log} = SerializableCoroutine.deserialize(json)

%Coroutine.Completed{result: {:ok, %{name: "Alice", email: "alice@example.com"}}} =
  SerializableCoroutine.run(log, sc, "alice@example.com")
```

## What's captured

The log records *every* effect invocation across *all* handlers —
`Yield`, `State`, `Writer`, `Port`, anything. If the wizard had
`State.modify` calls or `Writer.tell` calls, those would be in the
log too. The resume path replays them deterministically so the
computation sees exactly the same state it had before.

## Loop marking

For long-running computations with unbounded loops, use
`EffectLogger.mark_loop/1` to indicate restart points. This prevents
the log from growing without bound — the resume path prunes entries
before the most recent mark.

| Function | Purpose |
|----------|---------|
| `SerializableCoroutine.new(comp, handlers_fn)` | Build a serialisable coroutine |
| `SerializableCoroutine.get_log(suspended)` | Extract the effect log |
| `SerializableCoroutine.serialize(log)` | Serialize log to JSON |
| `SerializableCoroutine.deserialize(json)` | Restore log from JSON |
| `EffectLogger.with_resume(comp, log, value)` | Resume with replay |
| `EffectLogger.mark_loop(atom())` | Mark restart point to prune log |

<!-- nav:footer:start -->

---

[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:footer:end -->
