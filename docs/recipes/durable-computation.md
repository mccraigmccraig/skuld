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
handlers = fn comp ->
  comp |> Yield.with_handler() |> Throw.with_handler()
end

coroutine = SerializableCoroutine.new(wizard, handlers)
```

Run it — it suspends at the first yield:

```elixir
%Coroutine.ExternalSuspended{value: :get_name} = suspended =
  Coroutine.run(coroutine)
```

Extract and serialize the log. This is the computation's complete
effect history up to the suspension point:

```elixir
log = SerializableCoroutine.get_log(suspended)
json = SerializableCoroutine.serialize(log)
# => "[{\"sig\":\"Elixir.Skuld.Effects.Yield\",\"name\":\"yield\",\"args\":[\"get_name\"],\"result\":null}]"
```

The log shows that `Yield.yield(:get_name)` was called — that's the
only effect so far. There's no `result` because the computation hasn't
resumed yet. Persist `json` to a database, file, or message queue.

## Resume

Restore the log and build a new coroutine with the resume value:

```elixir
{:ok, log} = SerializableCoroutine.deserialize(json)

resume_coroutine =
  wizard
  |> EffectLogger.with_resume(log, "Alice")
  |> handlers.()
  |> then(&Coroutine.new(&1, Env.new()))
```

`with_resume` replays the logged effect history, then feeds `"Alice"`
as the resume value for the pending `Yield.yield(:get_name)`. Run it:

```elixir
%Coroutine.ExternalSuspended{value: :get_email} = suspended2 =
  Coroutine.run(resume_coroutine)
```

Serialize again. The log now shows the full history:

```elixir
log2 = SerializableCoroutine.get_log(suspended2)
json2 = SerializableCoroutine.serialize(log2)
# => "[{\"sig\":\"Elixir.Skuld.Effects.Yield\",\"name\":\"yield\",\"args\":[\"get_name\"],\"result\":\"Alice\"},
#      {\"sig\":\"Elixir.Skuld.Effects.Yield\",\"name\":\"yield\",\"args\":[\"get_email\"],\"result\":null}]"
```

The first yield now has `"result":"Alice"` — the resume value was
recorded. The second yield is pending (`"result":null`). One more
resume to finish:

```elixir
{:ok, log2d} = SerializableCoroutine.deserialize(json2)

final =
  wizard
  |> EffectLogger.with_resume(log2, "alice@example.com")
  |> handlers.()
  |> then(&Coroutine.new(&1, Env.new()))

%Coroutine.Completed{result: {:ok, %{name: "Alice", email: "alice@example.com"}}} =
  Coroutine.run(final)
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
