# EffectLogger & SerializableCoroutine

EffectLogger records every effect invocation in a computation into a
serializable log. SerializableCoroutine builds on this to provide
pause-serialize-resume workflows.

## EffectLogger

Records `{mod, name, args, result}` tuples for every effect call during
a computation's execution:

```elixir
{result, log} =
  my_comp
  |> EffectLogger.with_logging()
  |> State.with_handler(0)
  |> Reader.with_handler(%{})
  |> Throw.with_handler()
  |> Comp.run!()
```

The log is a list of `%LogEntry{}` structs — JSON-serializable records
of every effect invocation. EffectLogger must be installed **innermost**
(first in the pipe chain) so it wraps all other handlers.

### Durable workflows

The log enables pause-and-resume: serialize the log after a yield,
persist it, and later rebuild the computation with exactly the same
effect history:

```elixir
# Run until suspension
{%ExternalSuspend{value: v, data: data}, env} =
  wizard() |> EffectLogger.with_logging() |> ...handlers... |> Comp.run()

# Extract and serialize the log
log = data.log
json = Jason.encode!(log)

# Later: deserialize and resume
log = Jason.decode!(json)
{:ok, log_entries} = EffectLogger.Log.deserialize(log)

wizard()
|> EffectLogger.with_resume(log_entries, user_input)
|> ...same handlers...
|> Comp.run()
```

### Loop marking

For long-running loops, `EffectLogger.mark_loop/1` prevents log
unbounded growth by indicating restart points:

```elixir
EffectLogger.mark_loop(:process_next)
```

## SerializableCoroutine

A convenience wrapper combining Coroutine + EffectLogger:

```elixir
coroutine = SerializableCoroutine.new(my_comp, fn comp ->
  comp |> State.with_handler(0) |> Throw.with_handler()
end)

# Run until yield or completion
case Coroutine.run(coroutine) do
  %Coroutine.ExternalSuspended{value: value} = suspended ->
    log = SerializableCoroutine.get_log(suspended)
    json = SerializableCoroutine.serialize(log)
    # persist json...

    # Later: deserialize and build a new coroutine for resume
    {:ok, log} = SerializableCoroutine.deserialize(json)
    resume_comp =
      my_comp
      |> EffectLogger.with_resume(log, user_input)
      |> then(&stack_fun.(&1))

    Coroutine.run(Coroutine.new(resume_comp, Env.new()))
end
```

| Function | Purpose |
|----------|---------|
| `EffectLogger.with_logging(comp)` | Record effects during execution |
| `EffectLogger.with_resume(comp, log, value)` | Resume with replay |
| `SerializableCoroutine.new(comp, stack_fn)` | Build a coroutine with EffectLogger |
| `SerializableCoroutine.get_log(suspended)` | Extract log from suspended coroutine |
| `SerializableCoroutine.serialize(log)` | Serialize log to JSON string |
| `SerializableCoroutine.deserialize(json)` | Restore log from JSON string |
