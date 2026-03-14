# Effects: State & Environment

## State

Mutable state within a computation:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.State

comp do
  n <- State.get()
  _ <- State.put(n + 1)
  n
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {0, {:final_state, 1}}
```

## Reader

Read-only environment:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Reader

comp do
  name <- Reader.ask()
  "Hello, #{name}!"
end
|> Reader.with_handler("World")
|> Comp.run!()
#=> "Hello, World!"
```

## Writer

Accumulating output (use `output:` to include the log in the result):

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Writer

comp do
  _ <- Writer.tell("step 1")
  _ <- Writer.tell("step 2")
  :done
end
|> Writer.with_handler([], output: fn result, log -> {result, Enum.reverse(log)} end)
|> Comp.run!()
#=> {:done, ["step 1", "step 2"]}
```

## Multiple Independent Contexts (Tagged Usage)

State, Reader, and Writer all support explicit tags for multiple independent instances.
Use an atom as the first argument to operations, and `tag: :name` in the handler:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, Reader, Writer}

# Multiple independent state values
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

# Multiple independent reader contexts
comp do
  db <- Reader.ask(:db)
  api <- Reader.ask(:api)
  {db, api}
end
|> Reader.with_handler(%{host: "localhost"}, tag: :db)
|> Reader.with_handler(%{url: "https://api.example.com"}, tag: :api)
|> Comp.run!()
#=> {%{host: "localhost"}, %{url: "https://api.example.com"}}

# Multiple independent writer logs
comp do
  _ <- Writer.tell(:audit, "user logged in")
  _ <- Writer.tell(:metrics, {:counter, :login})
  _ <- Writer.tell(:audit, "viewed dashboard")
  :ok
end
|> Writer.with_handler([], tag: :audit, output: fn r, log -> {r, Enum.reverse(log)} end)
|> Writer.with_handler([], tag: :metrics, output: fn r, log -> {r, Enum.reverse(log)} end)
|> Comp.run!()
#=> {{:ok, ["user logged in", "viewed dashboard"]}, [{:counter, :login}]}
```

## Scoped State Transformation

Effects that use scoped state (State, Writer, Reader, Fresh, Random, Port, AtomicState)
support `:output` and `:suspend` options for transforming values at scope boundaries:

### :output - Transform result when leaving scope

When a computation completes, the `:output` function receives the result and final
state, returning a transformed result. This lets you include effect state in the
return value:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, Writer}

# Include final state in result
comp do
  _ <- State.put(42)
  :done
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {:done, {:final_state, 42}}

# Include accumulated log in result
comp do
  _ <- Writer.tell("step 1")
  _ <- Writer.tell("step 2")
  :done
end
|> Writer.with_handler([], output: fn result, log -> {result, Enum.reverse(log)} end)
|> Comp.run!()
#=> {:done, ["step 1", "step 2"]}
```

### :suspend - Decorate Suspend values when yielding

When a computation yields (via the Yield effect), the `:suspend` function can attach
effect state to the `Suspend.data` field. This is useful for:
- Exposing effect state to external runners (like AsyncComputation)
- Debugging and logging
- Cold resume scenarios

```elixir
alias Skuld.Comp.Suspend

# Attach state to suspend.data when yielding
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

The suspend decorator receives the `Suspend` struct and the current `env`, returning
a potentially modified `{suspend, env}` tuple. Multiple handlers with `:suspend`
options compose - inner handlers decorate first, outer handlers see and can further
modify the result.

EffectLogger uses this mechanism automatically when `:decorate_suspend` is true
(the default), attaching the current log to `Suspend.data[EffectLogger]` for
access by AsyncComputation callers.
