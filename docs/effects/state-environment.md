# State & Environment

<!-- nav:header:start -->
[< Syntax In Depth](../syntax.md) | [Index](../../README.md) | [Error Handling & Resources >](error-handling.md)
<!-- nav:header:end -->

The State, Reader, and Writer effects provide managed state and
environment within computations. They replace common patterns like
process dictionaries, configuration modules, and logging accumulators
with pure, testable alternatives.

## State

Mutable state within a computation.

### Basic usage

```elixir
comp do
  n <- State.get()
  _ <- State.put(n + 1)
  n
end
|> State.with_handler(0, output: fn result, state -> {result, state} end)
|> Comp.run!()
#=> {0, 1}
```

### Operations

- `State.get()` - get current state
- `State.put(value)` - replace state, returns `%Change{old: old, new: new}`
- `State.modify(fun)` - update state with a function, returns `%Change{}`

### Handler

```elixir
State.with_handler(initial_value, opts \\ [])
```

Options:
- `:tag` - atom tag for multiple independent states (see Tagged Usage below)
- `:output` - `fn result, final_state -> transformed_result end`
- `:suspend` - `fn suspend, env -> {suspend, env} end` (for Yield integration)

## Reader

Read-only environment, typically used for configuration or request context.

### Basic usage

```elixir
comp do
  name <- Reader.ask()
  "Hello, #{name}!"
end
|> Reader.with_handler("World")
|> Comp.run!()
#=> "Hello, World!"
```

### Operations

- `Reader.ask()` - get the environment value

### Handler

```elixir
Reader.with_handler(value, opts \\ [])
```

Options: `:tag`, `:output`, `:suspend` (same as State).

## Writer

Append-only log or accumulator.

### Basic usage

```elixir
comp do
  _ <- Writer.tell("step 1")
  _ <- Writer.tell("step 2")
  :done
end
|> Writer.with_handler([], output: fn result, log -> {result, Enum.reverse(log)} end)
|> Comp.run!()
#=> {:done, ["step 1", "step 2"]}
```

### Operations

- `Writer.tell(value)` - append to the log
- `Writer.listen(comp)` - run a computation and capture what it writes,
  returning `{result, captured_log}`

### Handler

```elixir
Writer.with_handler(initial_log, opts \\ [])
```

Options: `:tag`, `:output`, `:suspend` (same as State).

The log is a list; `tell` prepends to it. Use `Enum.reverse` in the
`:output` function if you need chronological order.

## Tagged usage

State, Reader, and Writer all support tags for multiple independent
instances. Pass an atom as the first argument to operations, and
`tag: :name` in the handler:

```elixir
comp do
  _ <- State.put(:counter, 0)
  _ <- State.modify(:counter, &(&1 + 1))
  count <- State.get(:counter)
  _ <- State.put(:name, "alice")
  name <- State.get(:name)
  {count, name}
end
|> State.with_handler(0, tag: :counter)
|> State.with_handler("", tag: :name)
|> Comp.run!()
#=> {1, "alice"}
```

This works identically for Reader and Writer:

```elixir
comp do
  db <- Reader.ask(:db)
  api <- Reader.ask(:api)
  {db, api}
end
|> Reader.with_handler(%{host: "localhost"}, tag: :db)
|> Reader.with_handler(%{url: "https://api.example.com"}, tag: :api)
|> Comp.run!()
#=> {%{host: "localhost"}, %{url: "https://api.example.com"}}
```

## Scoped state transforms

Effects with scoped state support `:output` and `:suspend` options for
transforming values at scope boundaries.

### `:output` - Transform result when leaving scope

When a computation completes, the `:output` function receives the result
and the handler's final state, returning a transformed result:

```elixir
comp do
  _ <- State.put(42)
  :done
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {:done, {:final_state, 42}}
```

This is how you extract handler state alongside the computation's return
value. Without `:output`, state is discarded when the handler's scope ends.

### `:suspend` - Decorate Suspend values when yielding

When a computation yields (via the Yield effect), the `:suspend` function
can attach effect state to the `Suspend.data` field:

```elixir
comp do
  _ <- State.put(42)
  _ <- Yield.yield(:checkpoint)
  :done
end
|> State.with_handler(0,
  suspend: fn suspend, env ->
    state = Skuld.Comp.Env.get_state(env, Skuld.Effects.State.state_key())
    data = suspend.data || %{}
    {%{suspend | data: Map.put(data, :state_snapshot, state)}, env}
  end
)
|> Yield.with_handler()
|> Comp.run()
#=> {%Suspend{value: :checkpoint, data: %{state_snapshot: 42}, ...}, _env}
```

Multiple handlers with `:suspend` options compose - inner handlers
decorate first, outer handlers can further modify the result. This
mechanism is used by EffectLogger and AsyncComputation to expose state
across suspension boundaries.

<!-- nav:footer:start -->

---

[< Syntax In Depth](../syntax.md) | [Index](../../README.md) | [Error Handling & Resources >](error-handling.md)
<!-- nav:footer:end -->
