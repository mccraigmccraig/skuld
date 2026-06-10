# EffectLogger & SerializableCoroutine

<!-- nav:header:start -->
[< skuld_durable](../../README.md) | [Index](../../README.md) | [SerializableCoroutine >](serializable-coroutine.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

EffectLogger records every effect invocation into a serialisable log.
SerializableCoroutine builds on this for pause-serialize-resume workflows.

## EffectLogger

Records each effect call as an `%EffectLogEntry{}` struct with fields
`sig`, `data`, `value`, and `state` (`:started`, `:executed`, `:discarded`).
The log is a flat list — flat structure, tree semantics via `leave_scope`.

```elixir
{result, log} =
  my_comp
  |> EffectLogger.with_logging()
  |> State.with_handler(0)
  |> Reader.with_handler(%{})
  |> Throw.with_handler()
  |> Comp.run()
```

`with_logging` returns `{result, log}` — the computation result paired
with the `%Log{}` struct. EffectLogger must be installed **innermost**
(first in the pipe) so it wraps all other handlers.

### Options

- `:effects` — list of effect sigs to log. Default `:all`.
- `:prune_loops` — enable `mark_loop/1` pruning (default `true`).
- `:state_keys` — filter which `env.state` keys to snapshot for cold resume.
- `:output` — transform `(result, log)` before returning. Default wraps as tuple.
- `:suspend` — decorate `ExternalSuspend.data` on yield. Default attaches the log.

### Replay

Pass an existing `%Log{}` to short-circuit completed effects:

```elixir
# First run — capture log
{{result1, log}, _} =
  my_comp
  |> EffectLogger.with_logging()
  |> State.with_handler(0)
  |> Comp.run()

# Replay — short-circuit with logged values
{{result2, _}, _} =
  my_comp
  |> EffectLogger.with_logging(log)
  |> State.with_handler(0)
  |> Comp.run()

assert result1 == result2
```

### Loop marking

`mark_loop/1` prevents log unbounded growth in long-running loops.
Each mark captures an `EnvStateSnapshot` for cold resume. With
`prune_loops: true`, completed iterations are pruned on finalisation:

```elixir
defcomp conversation_loop(state) do
  _ <- EffectLogger.mark_loop(ConversationLoop)
  input <- Yield.yield(:await_input)
  state = handle_input(state, input)
  conversation_loop(state)
end

{{result, log}, _} =
  conversation_loop(initial_state)
  |> EffectLogger.with_logging(prune_loops: true)
  |> Yield.with_handler()
  |> Comp.run()
```

### Cold resume

Replay logged history and inject a value at the suspension point.
`with_resume/3` restores `env.state` from the most recent checkpoint,
replays completed effects, and injects `resume_value` where the
computation previously suspended:

```elixir
# Original run — suspended at a Yield
{%ExternalSuspend{}, log} =
  wizard()
  |> EffectLogger.with_logging()
  |> Yield.with_handler()
  |> State.with_handler(0)
  |> Comp.run()

# Persist and restore
json = Log.to_json(log)
{:ok, restored_log} = Log.from_json(json)

# Cold resume with injected value
{{result, new_log}, _} =
  wizard()
  |> EffectLogger.with_resume(restored_log, :user_input)
  |> Yield.with_handler()
  |> State.with_handler(0)
  |> Comp.run()
```

## SerializableCoroutine

Convenience wrapper combining Coroutine + EffectLogger for the
common pause-serialize-resume pattern:

```elixir
sc = SerializableCoroutine.new(my_comp, fn comp ->
  comp |> State.with_handler(0) |> Throw.with_handler()
end)

case SerializableCoroutine.run(sc) do
  %Coroutine.ExternalSuspended{} = suspended ->
    json = SerializableCoroutine.serialize(SerializableCoroutine.get_log(suspended))

    {:ok, log} = SerializableCoroutine.deserialize(json)
    SerializableCoroutine.run(log, sc, user_input)
end
```

| Operation | Purpose |
|-----------|---------|
| `EffectLogger.with_logging(comp, opts)` | Record effects during execution |
| `EffectLogger.with_logging(comp, log, opts)` | Replay from existing log |
| `EffectLogger.with_resume(comp, log, value)` | Cold resume with injected value |
| `EffectLogger.mark_loop(loop_id)` | Mark loop iteration boundary for pruning |
| `Log.to_list(log)` | View log entries as `%EffectLogEntry{}` list |
| `Log.to_json(log)` | Serialize log to JSON |
| `Log.from_json(json)` | Deserialize log from JSON |
| `SerializableCoroutine.new(comp, stack_fn)` | Build a coroutine with EffectLogger |
| `SerializableCoroutine.get_log(suspended)` | Extract log from suspended coroutine |
| `SerializableCoroutine.serialize(log)` | Serialize log to JSON string |
| `SerializableCoroutine.deserialize(json)` | Restore log from JSON string |

<!-- nav:footer:start -->

---

[< skuld_durable](../../README.md) | [Index](../../README.md) | [SerializableCoroutine >](serializable-coroutine.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
