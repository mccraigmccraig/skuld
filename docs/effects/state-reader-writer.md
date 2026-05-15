# State, Reader & Writer

<!-- nav:header:start -->
[< Getting Started](../getting-started.md) | [Index](../../README.md) | [Throw & Bracket >](throw-bracket.md)
<!-- nav:header:end -->

The three foundational effects for managing context within a computation.

## State

Mutable state scoped to a computation. Operations:

```elixir
x <- State.get()           # read current value
_ <- State.put(val)        # replace state
_ <- State.modify(fn x -> x + 1 end)  # update via function
x <- State.gets(fn s -> s.count end)  # read with accessor
```

Tagged variants for multiple independent states:

```elixir
x <- State.get(:counter)   # read tagged state
_ <- State.put(:counter, 0)
```

Handler installation:

```elixir
computation |> State.with_handler(initial_value)
computation |> State.with_handler(0, tag: :counter)
```

The `output` option transforms the result before returning:

```elixir
computation |> State.with_handler(0, output: fn result, final_state ->
  {result, final_state}  # include final state in result
end)
```

## Reader

Read-only configuration, scoped to a computation:

```elixir
config <- Reader.ask()           # read current value
val <- Reader.asks(fn c -> c.key end)  # read with accessor
```

Scoped overrides within a computation:

```elixir
Reader.local(fn config -> Map.put(config, :timeout, 5000) end, inner_comp)
```

Handler installation:

```elixir
computation |> Reader.with_handler(%{timeout: 5000, env: :prod})
```

## Writer

Append-only log, collected in order:

```elixir
_ <- Writer.tell(%SomeEvent{})      # append an event
_ <- Writer.tell(:audit, %LogEntry{})  # tagged writer
```

Reading and scoping:

```elixir
log <- Writer.peek()               # read current log
Writer.listen(inner_comp)          # isolate inner writer
Writer.pass(inner_comp)            # isolate, then merge into outer
Writer.censor(inner_comp, &Enum.filter(&1, fn e -> ... end))  # isolate with filter
```

Handler installation:

```elixir
computation |> Writer.with_handler([])
computation |> Writer.with_handler([], tag: :audit)
computation |> Writer.with_handler([], output: fn result, log ->
  {result, Enum.reverse(log)}  # log in chronological order
end)
```

## State & Environment overview

| Effect | Read | Write | Transform | Tagged | Handler |
|--------|------|-------|-----------|--------|---------|
| State | `get/0,1`, `gets/1,2` | `put/1,2` | `modify/1,2` | Yes | `with_handler(comp, initial, opts)` |
| Reader | `ask/0,1`, `asks/1,2` | — | `local/2,3` | Yes | `with_handler(comp, value, opts)` |
| Writer | `peek/0,1` | `tell/1,2` | `listen/1,2`, `pass/1,2`, `censor/2,3` | Yes | `with_handler(comp, initial, opts)` |

All three support the `output` option for transforming the final result
with handler state, and `suspend` for decorating `ExternalSuspend` data
when the computation yields.

<!-- nav:footer:start -->

---

[< Getting Started](../getting-started.md) | [Index](../../README.md) | [Throw & Bracket >](throw-bracket.md)
<!-- nav:footer:end -->
