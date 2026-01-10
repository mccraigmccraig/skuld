# Skuld

[![Test](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/skuld.svg)](https://hex.pm/packages/skuld)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/skuld/)

Evidence-passing Algebraic Effects for Elixir.

Skuld is a clean, efficient implementation of Algebraic Effects using evidence-passing
style with CPS (continuation-passing style) for control effects. It provides scoped
handlers, coroutines via Yield, and composable effect stacks.

Skuld's client API looks quite similar to
[Freyja](https://github.com/mccraigmccraig/freyja),
but the implementation is very different. Skuld performs better and has a
simpler and more coherent API, and is (arguably) easier to understand.

## Features

- **Evidence-passing style**: Handlers are looked up directly from a map in the
  dynamic environment
- **CPS for control effects**: Enables proper support for control flow effects
  like Yield and Throw
- **Scoped handlers**: Handlers are automatically installed/restored with proper
  cleanup
- **Composable**: Multiple effects can be stacked and composed naturally
- **Single type**: Single unified `computation` type and `comp` macro for all
  effectful code (unlike Freyja, there's no first-order / higher-order split)
- **Auto-lifting**: Plain values are automatically lifted to computations,
  enabling ergonomic patterns like `if` without `else` and implicit final returns

## Installation

Add `skuld` to your list of dependencies in `mix.exs` (see the [Hex package](https://hex.pm/packages/skuld) for the current version):

```elixir
def deps do
  [
    {:skuld, "~> x.y"}
  ]
end
```

## Demo Application

See [TodosMcp](https://github.com/mccraigmccraig/todos_mcp) - a 
voice-controllable todo application built with Skuld. It demonstrates how 
command/query structs combined with algebraic effects enable trivial LLM 
integration and property-based testing. Try it live at 
https://todos-mcp-lu6h.onrender.com/

## Quick Start

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, Reader, Writer, Throw, Yield}

# Define a computation using the comp macro
defmodule Example do
  defcomp example() do
    # Read from Reader effect
    config <- Reader.ask()

    # Get and update State
    count <- State.get()
    _ <- State.put(count + 1)

    # Write to Writer effect
    _ <- Writer.tell("processed item #{count}")

    {config, count}  # final expression auto-lifted (no return needed)
  end
end

# Run with handlers installed
Example.example()
  |> Reader.with_handler(:my_config)
  |> State.with_handler(0, output: fn r, st -> {r, {:final_state, st}} end)
  |> Writer.with_handler([], output: fn r, w -> {r, {:log, w}} end)
  |> Comp.run!()

#=> {{{:my_config, 0}, {:final_state, 1}}, {:log, ["processed item 0"]}}
```

## Effects

All examples below assume the following setup (paste once into IEx):

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{
  State, Reader, Writer, Throw, Yield,
  FxList, FxFasterList,
  Fresh, Bracket, Query, Command, EventAccumulator, EffectLogger,
  DBTransaction, EctoPersist
}
alias Skuld.Effects.DBTransaction.Noop, as: NoopTx
alias Skuld.Effects.DBTransaction.Ecto, as: EctoTx
```

### State

Mutable state within a computation:

```elixir
comp do
  n <- State.get()
  _ <- State.put(n + 1)
  n
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {0, {:final_state, 1}}
```

### Reader

Read-only environment:

```elixir
comp do
  name <- Reader.ask()
  "Hello, #{name}!"
end
|> Reader.with_handler("World")
|> Comp.run!()
#=> "Hello, World!"
```

### Writer

Accumulating output (use `output:` to include the log in the result):

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

### Throw

Error handling with the `catch` clause:

```elixir
comp do
  x = -1
  _ <- if x < 0, do: Throw.throw({:error, "negative"})  # nil auto-lifted when false
  x * 2
catch
  err -> {:recovered, err}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:recovered, {:error, "negative"}}
```

The `catch` clause desugars to `Throw.catch_error/2`:

```elixir
# The above is equivalent to:
Throw.catch_error(
  comp do
    x = -1
    _ <- if x < 0, do: Throw.throw({:error, "negative"})
    x * 2
  end,
  fn err -> comp do {:recovered, err} end end
)
|> Throw.with_handler()
|> Comp.run!()
#=> {:recovered, {:error, "negative"}}
```

Elixir's `raise`, `throw`, and `exit` are automatically converted to Throw effects
when they occur during computation execution. This works even in the first expression
of a comp block:

```elixir
# Helper functions that raise/throw
defmodule Risky do
  def boom!, do: raise "oops!"
  def throw_ball!, do: throw(:ball)
end

# Elixir raise is caught and converted - even as the first expression
comp do
  Risky.boom!()
catch
  %{kind: :error, payload: %RuntimeError{message: msg}} -> {:caught_raise, msg}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:caught_raise, "oops!"}

# Elixir throw is also converted
comp do
  Risky.throw_ball!()
catch
  %{kind: :throw, payload: value} -> {:caught_throw, value}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:caught_throw, :ball}
```

The converted error is a map with `:kind`, `:payload`, and `:stacktrace` keys,
allowing you to handle different error types uniformly.

### Pattern Matching with Else

The `else` clause handles pattern match failures in `<-` bindings. Since `else`
uses the Throw effect internally, you need a Throw handler:

```elixir
comp do
  {:ok, x} <- {:error, "something went wrong"}  # auto-lifted
  x * 2
else
  {:error, reason} -> {:match_failed, reason}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:match_failed, "something went wrong"}
```

### Combining Else and Catch

Both clauses can be used together. The `else` must come before `catch`:

```elixir
# Returns {:ok, x}, {:error, reason}, or throws
might_fail = fn x ->
  cond do
    x < 0 -> {:error, :negative}  # auto-lifted
    x > 100 -> Throw.throw(:too_large)
    true -> {:ok, x}  # auto-lifted
  end
end

# Throw case (x > 100):
comp do
  {:ok, x} <- might_fail.(150)
  x * 2
else
  {:error, reason} -> {:match_failed, reason}
catch
  err -> {:caught_throw, err}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:caught_throw, :too_large}

# Match failure case (x < 0):
comp do
  {:ok, x} <- might_fail.(-5)
  x * 2
else
  {:error, reason} -> {:match_failed, reason}
catch
  err -> {:caught_throw, err}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:match_failed, :negative}
```

The semantic ordering is `catch(else(body))`, meaning:
- `else` handles pattern match failures from the main computation
- `catch` handles throws from both the main computation AND the else handler

### Yield

Coroutine-style suspension and resumption:

```elixir
generator = comp do
  _ <- Yield.yield(1)
  _ <- Yield.yield(2)
  _ <- Yield.yield(3)
  :done
end

# Collect all yielded values
generator
|> Yield.with_handler()
|> Yield.collect()
#=> {:done, :done, [1, 2, 3], _env}

# Or drive with a custom function
generator
|> Yield.with_handler()
|> Yield.run_with_driver(fn yielded ->
  IO.puts("Got: #{yielded}")
  {:continue, :ok}
end)
# Prints: Got: 1, Got: 2, Got: 3
#=> {:done, :done, _env}
```

### FxList

Effectful list operations:

```elixir
comp do
  results <- FxList.fx_map([1, 2, 3], fn item ->
    comp do
      count <- State.get()
      _ <- State.put(count + 1)
      item * 2
    end
  end)
  results
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {[2, 4, 6], {:final_state, 3}}
```

> **Note**: For large iteration counts (10,000+), use `Yield`-based coroutines instead
> of `FxList` for better performance. See the FxList module docs for details.

### FxFasterList

High-performance variant of FxList using `Enum.reduce_while`:

```elixir
comp do
  results <- FxFasterList.fx_map([1, 2, 3], fn item ->
    comp do
      count <- State.get()
      _ <- State.put(count + 1)
      item * 2
    end
  end)
  results
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {[2, 4, 6], {:final_state, 3}}
```

> **Note**: FxFasterList is ~2x faster than FxList but has limited Yield/Suspend support.
> Use it when performance is critical and you only use Throw for error handling.

### Multiple Independent Contexts (Tagged Usage)

State, Reader, and Writer all support explicit tags for multiple independent instances.
Use an atom as the first argument to operations, and `tag: :name` in the handler:

```elixir
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

### Fresh

Generate fresh UUIDs with two handler modes:

```elixir
# Production: v7 UUIDs (time-ordered, good for database primary keys)
comp do
  uuid1 <- Fresh.fresh_uuid()
  uuid2 <- Fresh.fresh_uuid()
  {uuid1, uuid2}
end
|> Fresh.with_uuid7_handler()
|> Comp.run!()
#=> {"01945a3b-...", "01945a3b-..."}  # time-ordered, unique

# Testing: deterministic v5 UUIDs (reproducible given same namespace)
namespace = Uniq.UUID.uuid4()

comp do
  uuid1 <- Fresh.fresh_uuid()
  uuid2 <- Fresh.fresh_uuid()
  {uuid1, uuid2}
end
|> Fresh.with_test_handler(namespace: namespace)
|> Comp.run!()
#=> {"550e8400-...", "6ba7b810-..."}

# Same namespace always produces same sequence - great for testing!
comp do
  uuid <- Fresh.fresh_uuid()
  uuid
end
|> Fresh.with_test_handler(namespace: namespace)
|> Comp.run!()
#=> "550e8400-..."  # same UUID every time with same namespace
```

### Bracket

Safe resource acquisition and cleanup (like try/finally):

```elixir
# Track resource lifecycle with State
comp do
  result <- Bracket.bracket(
    # Acquire
    comp do
      _ <- State.put(:acquired)
      :resource
    end,
    # Release (always runs)
    fn _resource ->
      comp do
        _ <- State.put(:released)
        :ok
      end
    end,
    # Use
    fn resource ->
      {:used, resource}  # auto-lifted
    end
  )
  final_state <- State.get()
  {result, final_state}
end
|> State.with_handler(:init)
|> Comp.run!()
#=> {{:used, :resource}, :released}
```

Use `Bracket.finally/2` for simpler cleanup without resource passing:

```elixir
Bracket.finally(
  comp do
    _ <- State.put(:working)
    :done
  end,
  comp do
    _ <- State.put(:cleaned_up)
    :ok
  end
)
|> State.with_handler(:init, output: fn r, s -> {r, s} end)
|> Comp.run!()
#=> {:done, :cleaned_up}
```

### DBTransaction

Database transactions with automatic commit/rollback:

```elixir
# Normal completion - transaction commits
comp do
  result <- DBTransaction.transact(comp do
    {:user_created, 123}
  end)
  result
end
|> NoopTx.with_handler()
|> Comp.run!()
#=> {:user_created, 123}

# Explicit rollback
comp do
  result <- DBTransaction.transact(comp do
    _ <- DBTransaction.rollback(:validation_failed)
    :never_reached
  end)
  result
end
|> NoopTx.with_handler()
|> Comp.run!()
#=> {:rolled_back, :validation_failed}
```

The same domain code works with different handlers - swap `Noop` for `Ecto` in production:

```elixir
# Domain logic - unchanged regardless of handler
create_order = fn user_id, items ->
  comp do
    result <- DBTransaction.transact(comp do
      # Imagine these are real Ecto operations
      order = %{id: 1, user_id: user_id, items: items}
      order
    end)
    result
  end
end

# Production: real Ecto transactions (won't work in IEX!)
create_order.(123, [:item_a, :item_b])
|> EctoTx.with_handler(MyApp.Repo)
|> Comp.run!()
#=> %{id: 1, user_id: 123, items: [:item_a, :item_b]}

# Testing: no database, same domain code
create_order.(123, [:item_a, :item_b])
|> NoopTx.with_handler()
|> Comp.run!()
#=> %{id: 1, user_id: 123, items: [:item_a, :item_b]}
```

### Query

Backend-agnostic data queries with pluggable handlers:

```elixir
# Define a query module (in real code, this would have actual implementations)
defmodule MyQueries do
  def find_user(%{id: id}), do: %{id: id, name: "User #{id}"}
end

# Runtime: dispatch to actual query modules
comp do
  user <- Query.request(MyQueries, :find_user, %{id: 123})
  user
end
|> Query.with_handler(%{MyQueries => :direct})
|> Comp.run!()
#=> %{id: 123, name: "User 123"}

# Test: stub responses
comp do
  user <- Query.request(MyQueries, :find_user, %{id: 456})
  user
end
|> Query.with_test_handler(%{
  Query.key(MyQueries, :find_user, %{id: 456}) => %{id: 456, name: "Stubbed"}
})
|> Throw.with_handler()
|> Comp.run!()
#=> %{id: 456, name: "Stubbed"}
```

### Command

Dispatch commands (mutations) through a unified handler:

```elixir
# Define command structs
defmodule CreateTodo do
  defstruct [:title, :priority]
end

defmodule DeleteTodo do
  defstruct [:id]
end

# Define a command handler that routes via pattern matching
defmodule MyCommandHandler do
  use Skuld.Syntax

  def handle(%CreateTodo{title: title, priority: priority}) do
    comp do
      id <- Fresh.fresh_uuid()
      {:ok, %{id: id, title: title, priority: priority}}
    end
  end

  def handle(%DeleteTodo{id: id}) do
    comp do
      {:ok, %{deleted: id}}
    end
  end
end

# Execute commands through the effect system
comp do
  {:ok, todo} <- Command.execute(%CreateTodo{title: "Buy milk", priority: :high})
  todo
end
|> Command.with_handler(&MyCommandHandler.handle/1)
|> Fresh.with_uuid7_handler()
|> Comp.run!()
#=> %{id: "01945a3b-...", title: "Buy milk", priority: :high}
```

The handler function returns a computation, so commands can use other effects
(Fresh, EctoPersist, EventAccumulator, etc.) internally. This enables a clean
separation between command dispatch and command implementation.

### EventAccumulator

Accumulate domain events during computation (built on Writer):

```elixir
comp do
  _ <- EventAccumulator.emit(%{type: :user_created, id: 1})
  _ <- EventAccumulator.emit(%{type: :email_sent, to: "user@example.com"})
  :ok
end
|> EventAccumulator.with_handler(output: fn result, events -> {result, events} end)
|> Comp.run!()
#=> {:ok, [%{type: :user_created, id: 1}, %{type: :email_sent, to: "user@example.com"}]}
```

### EffectLogger

Capture effect invocations for replay, resume, and retry:

```elixir
# Capture a log of effects
{{result, log}, _env} = (
  comp do
    x <- State.get()
    _ <- State.put(x + 10)
    y <- State.get()
    {x, y}
  end
  |> EffectLogger.with_logging()
  |> State.with_handler(0)
  |> Comp.run()
)

result
#=> {0, 10}

# The log captures each effect invocation with its result
log
#=> %Skuld.Effects.EffectLogger.Log{
#=>   effect_queue: [
#=>     %EffectLogEntry{sig: State, data: %State.Get{}, value: 0, state: :executed},
#=>     %EffectLogEntry{sig: State, data: %State.Put{value: 10}, value: %Change{old: 0, new: 10}, state: :executed},
#=>     %EffectLogEntry{sig: State, data: %State.Get{}, value: 10, state: :executed}
#=>   ],
#=>   ...
#=> }

# Replay with different initial state - uses logged values instead of executing
{{replayed, _log2}, _env2} = (
  comp do
    x <- State.get()
    _ <- State.put(x + 10)
    y <- State.get()
    {x, y}
  end
  |> EffectLogger.with_logging(log)
  |> State.with_handler(999)  # Different initial state - ignored during replay!
  |> Comp.run()
)

replayed
#=> {0, 10}  # Same result - values came from log, not from State handler
```

### EctoPersist

Ecto database operations as effects (requires Ecto):

```elixir
# Production: real database operations
comp do
  user <- EctoPersist.insert(User.changeset(%User{}, %{name: "Alice"}))
  order <- EctoPersist.insert(Order.changeset(%Order{}, %{user_id: user.id}))
  {user, order}
end
|> EctoPersist.with_handler(MyApp.Repo)
|> Comp.run!()
```

For testing, use the test handler to stub responses and record calls:

```elixir
# Test handler applies changeset changes and records all operations
{result, calls} =
  comp do
    user <- EctoPersist.insert(User.changeset(%User{}, %{name: "Alice"}))
    _ <- EctoPersist.update(User.changeset(user, %{name: "Bob"}))
    user
  end
  |> EctoPersist.with_test_handler(&EctoPersist.TestHandler.default_handler/1)
  |> Comp.run!()

result
#=> %User{name: "Alice"}

calls
#=> [{:insert, %Ecto.Changeset{...}}, {:update, %Ecto.Changeset{...}}]

# Custom handler for specific test scenarios
comp do
  user <- EctoPersist.insert(changeset)
  user
end
|> EctoPersist.with_test_handler(fn
  %EctoPersist.Insert{input: cs} -> %User{id: "test-id", name: "Stubbed"}
  %EctoPersist.Update{input: cs} -> Ecto.Changeset.apply_changes(cs)
end)
|> Comp.run!()
#=> {%User{id: "test-id", name: "Stubbed"}, [{:insert, changeset}]}
```

> **Note**: EctoPersist wraps Ecto Repo operations. See the module docs for
> `insert`, `update`, `delete`, `insert_all`, `update_all`, `delete_all`, and `upsert`.

## Architecture

Skuld uses evidence-passing style where:

1. **Handlers** are stored in the environment as functions
2. **Effects** look up their handler and call it directly
3. **CPS** enables control effects (Yield, Throw) to manipulate continuations
4. **Scoped handlers** automatically manage handler installation/cleanup

## Comparison with Freyja

Skuld is a cleaner, faster alternative to Freyja:

| Aspect | Freyja | Skuld |
|--------|--------|-------|
| Effect representation | Freer monad + Hefty algebras | Evidence-passing CPS |
| Computation types | `Freer` + `Hefty` | Just `computation` |
| Control effects | Hefty (higher-order) | Direct CPS |
| Handler lookup | Search through handler list | Direct map lookup |
| Macro system | `con` + `hefty` | Single `comp` |

Skuld's performance advantage comes from avoiding Freer monad object allocation,
continuation queue management, and linear search for handlers.

## Performance

Benchmark comparing Skuld against pure baselines and minimal effect implementations.
Run with `mix run bench/skuld_benchmark.exs`.

**What's being measured:** A loop that increments a counter from 0 to N using
`State.get()` / `State.put(n + 1)` operations. This exercises the core effect
invocation path repeatedly, measuring per-operation overhead.

### Core Benchmark

| Target | Pure/Rec | Monad | Evf | Evf/CPS | Skuld/Nest | Skuld/FxFL |
|--------|----------|-------|-----|---------|------------|------------|
| 500 | 4 µs | 10 µs | 17 µs | 17 µs | 141 µs | 54 µs |
| 1000 | 28 µs | 55 µs | 56 µs | 58 µs | 255 µs | 166 µs |
| 2000 | 34 µs | 78 µs | 91 µs | 97 µs | 558 µs | 325 µs |
| 5000 | 82 µs | 189 µs | 244 µs | 258 µs | 1.42 ms | 836 µs |
| 10000 | 145 µs | 157 µs | 298 µs | 325 µs | 2.3 ms | 960 µs |

**Implementations compared:**

- **Pure/Rec** - Non-effectful baseline using tail recursion with map state
- **Monad** - Simple state monad (`fn state -> {val, state} end`) with no effect system
- **Evf** - Flat evidence-passing, direct-style (no CPS) - can't support control effects
- **Evf/CPS** - Flat evidence-passing with CPS - isolates CPS overhead (~1.1x vs Evf)
- **Skuld/Nest** - Skuld with nested `Comp.bind` calls (typical usage pattern)
- **Skuld/FxFL** - Skuld with `FxFasterList` iteration (optimized for collections)

### Iteration Strategies

| Target | FxFasterList | FxList | Yield |
|--------|--------------|--------|-------|
| 1000 | 97 µs (0.10 µs/op) | 200 µs (0.20 µs/op) | 147 µs (0.15 µs/op) |
| 5000 | 492 µs (0.10 µs/op) | 959 µs (0.19 µs/op) | 762 µs (0.15 µs/op) |
| 10000 | 1.02 ms (0.10 µs/op) | 2.71 ms (0.27 µs/op) | 1.52 ms (0.15 µs/op) |
| 50000 | 5.1 ms (0.10 µs/op) | - | 7.58 ms (0.15 µs/op) |
| 100000 | 10.02 ms (0.10 µs/op) | - | 14.9 ms (0.15 µs/op) |

**Iteration options:**

- **FxFasterList** - Uses `Enum.reduce_while`, fastest option (~2x faster than FxList)
- **FxList** - Uses `Comp.bind` chains, supports full Yield/Suspend resume semantics
- **Yield** - Coroutine-style suspend/resume, use when you need interruptible iteration

All three maintain constant per-operation cost as N grows.

### Key Takeaways

1. **CPS overhead is minimal** - Evf/CPS is only ~1.1x slower than direct-style Evf
2. **Skuld overhead** (~7x vs Evf/CPS) comes from scoped handlers, exception handling, and auto-lifting
3. **FxFasterList** is the fastest iteration strategy when you don't need Yield semantics
4. **Per-op cost is constant** - no quadratic blowup at scale

## License

MIT License - see [LICENSE](LICENSE) for details.
