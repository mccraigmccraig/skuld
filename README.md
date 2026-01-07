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

## Installation

Add `skuld` to your list of dependencies in `mix.exs` (see the [Hex package](https://hex.pm/packages/skuld) for the current version):

```elixir
def deps do
  [
    {:skuld, "~> x.y"}
  ]
end
```

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

    return({config, count})
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

Each example below can be copy/pasted directly into IEx.

### State

Mutable state within a computation:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.State

comp do
  n <- State.get()
  _ <- State.put(n + 1)
  return(n)
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {0, {:final_state, 1}}
```

### Reader

Read-only environment:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Reader

comp do
  name <- Reader.ask()
  return("Hello, #{name}!")
end
|> Reader.with_handler("World")
|> Comp.run!()
#=> "Hello, World!"
```

### Writer

Accumulating output (use `output:` to include the log in the result):

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Writer

comp do
  _ <- Writer.tell("step 1")
  _ <- Writer.tell("step 2")
  return(:done)
end
|> Writer.with_handler([], output: fn result, log -> {result, Enum.reverse(log)} end)
|> Comp.run!()
#=> {:done, ["step 1", "step 2"]}
```

### Throw

Error handling with the `catch` clause:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Throw

comp do
  x = -1
  _ <- if x < 0, do: Throw.throw({:error, "negative"}), else: return(:ok)
  return(x * 2)
catch
  err -> return({:recovered, err})
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
    _ <- if x < 0, do: Throw.throw({:error, "negative"}), else: return(:ok)
    return(x * 2)
  end,
  fn err -> comp do return({:recovered, err}) end end
)
|> Throw.with_handler()
|> Comp.run!()
#=> {:recovered, {:error, "negative"}}
```

### Pattern Matching with Else

The `else` clause handles pattern match failures in `<-` bindings. Since `else`
uses the Throw effect internally, you need a Throw handler:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Throw

comp do
  {:ok, x} <- return({:error, "something went wrong"})
  return(x * 2)
else
  {:error, reason} -> return({:match_failed, reason})
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:match_failed, "something went wrong"}
```

### Combining Else and Catch

Both clauses can be used together. The `else` must come before `catch`:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Throw

# Returns {:ok, x}, {:error, reason}, or throws
might_fail = fn x ->
  cond do
    x < 0 -> Comp.return({:error, :negative})
    x > 100 -> Throw.throw(:too_large)
    true -> Comp.return({:ok, x})
  end
end

# Throw case (x > 100):
comp do
  {:ok, x} <- might_fail.(150)
  return(x * 2)
else
  {:error, reason} -> return({:match_failed, reason})
catch
  err -> return({:caught_throw, err})
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:caught_throw, :too_large}

# Match failure case (x < 0):
comp do
  {:ok, x} <- might_fail.(-5)
  return(x * 2)
else
  {:error, reason} -> return({:match_failed, reason})
catch
  err -> return({:caught_throw, err})
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
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Yield

generator = comp do
  _ <- Yield.yield(1)
  _ <- Yield.yield(2)
  _ <- Yield.yield(3)
  return(:done)
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
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, FxList}

comp do
  results <- FxList.fx_map([1, 2, 3], fn item ->
    comp do
      count <- State.get()
      _ <- State.put(count + 1)
      return(item * 2)
    end
  end)
  return(results)
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
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, FxFasterList}

comp do
  results <- FxFasterList.fx_map([1, 2, 3], fn item ->
    comp do
      count <- State.get()
      _ <- State.put(count + 1)
      return(item * 2)
    end
  end)
  return(results)
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {[2, 4, 6], {:final_state, 3}}
```

> **Note**: FxFasterList is ~2x faster than FxList but has limited Yield/Suspend support.
> Use it when performance is critical and you only use Throw for error handling.

### TaggedState

Multiple independent mutable state values identified by tags:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.TaggedState

comp do
  _ <- TaggedState.put(:counter, 0)
  _ <- TaggedState.modify(:counter, &(&1 + 1))
  count <- TaggedState.get(:counter)
  _ <- TaggedState.put(:name, "alice")
  name <- TaggedState.get(:name)
  return({count, name})
end
|> TaggedState.with_handler(:counter, 0)
|> TaggedState.with_handler(:name, "")
|> Comp.run!()
#=> {1, "alice"}
```

### TaggedReader

Multiple independent read-only environments identified by tags:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.TaggedReader

comp do
  db <- TaggedReader.ask(:db)
  api <- TaggedReader.ask(:api)
  return({db, api})
end
|> TaggedReader.with_handler(:db, %{host: "localhost"})
|> TaggedReader.with_handler(:api, %{url: "https://api.example.com"})
|> Comp.run!()
#=> {%{host: "localhost"}, %{url: "https://api.example.com"}}
```

### TaggedWriter

Multiple independent accumulating logs identified by tags:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.TaggedWriter

comp do
  _ <- TaggedWriter.tell(:audit, "user logged in")
  _ <- TaggedWriter.tell(:metrics, {:counter, :login})
  _ <- TaggedWriter.tell(:audit, "viewed dashboard")
  return(:ok)
end
|> TaggedWriter.with_handler(:audit, [], output: fn r, log -> {r, Enum.reverse(log)} end)
|> TaggedWriter.with_handler(:metrics, [], output: fn r, log -> {r, Enum.reverse(log)} end)
|> Comp.run!()
#=> {{:ok, ["user logged in", "viewed dashboard"]}, [{:counter, :login}]}
```

### Fresh

Generate fresh/unique values (sequential integers and deterministic UUIDs):

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Fresh

# Generate sequential integers (default starts at 0)
comp do
  id1 <- Fresh.fresh()
  id2 <- Fresh.fresh()
  return({id1, id2})
end
|> Fresh.with_handler()
|> Comp.run!()
#=> {0, 1}

# Seed the counter to start from a different value
comp do
  id1 <- Fresh.fresh()
  id2 <- Fresh.fresh()
  return({id1, id2})
end
|> Fresh.with_handler(seed: 1000)
|> Comp.run!()
#=> {1000, 1001}

# Generate deterministic UUIDs (v5) - reproducible given the same namespace
namespace = UUID.uuid4()

comp do
  uuid1 <- Fresh.fresh_uuid()
  uuid2 <- Fresh.fresh_uuid()
  return({uuid1, uuid2})
end
|> Fresh.with_handler(namespace: namespace)
|> Comp.run!()
#=> {"550e8400-...", "6ba7b810-..."}

# Same namespace always produces same sequence - great for testing!
```

### Bracket

Safe resource acquisition and cleanup (like try/finally):

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Bracket, State, Throw}

# Track resource lifecycle with State
comp do
  result <- Bracket.bracket(
    # Acquire
    comp do
      _ <- State.put(:acquired)
      return(:resource)
    end,
    # Release (always runs)
    fn _resource ->
      comp do
        _ <- State.put(:released)
        return(:ok)
      end
    end,
    # Use
    fn resource ->
      comp do
        return({:used, resource})
      end
    end
  )
  final_state <- State.get()
  return({result, final_state})
end
|> State.with_handler(:init)
|> Comp.run!()
#=> {{:used, :resource}, :released}
```

Use `Bracket.finally/2` for simpler cleanup without resource passing:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Bracket, State}

Bracket.finally(
  comp do
    _ <- State.put(:working)
    return(:done)
  end,
  comp do
    _ <- State.put(:cleaned_up)
    return(:ok)
  end
)
|> State.with_handler(:init, output: fn r, s -> {r, s} end)
|> Comp.run!()
#=> {:done, :cleaned_up}
```

### DBTransaction

Database transactions with automatic commit/rollback:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.DBTransaction
alias Skuld.Effects.DBTransaction.Noop, as: NoopTx

# Normal completion - transaction commits
comp do
  result <- DBTransaction.transact(comp do
    return({:user_created, 123})
  end)
  return(result)
end
|> NoopTx.with_handler()
|> Comp.run!()
#=> {:user_created, 123}

# Explicit rollback
comp do
  result <- DBTransaction.transact(comp do
    _ <- DBTransaction.rollback(:validation_failed)
    return(:never_reached)
  end)
  return(result)
end
|> NoopTx.with_handler()
|> Comp.run!()
#=> {:rolled_back, :validation_failed}
```

The same domain code works with different handlers - swap `Noop` for `Ecto` in production:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.DBTransaction
alias Skuld.Effects.DBTransaction.Ecto, as: EctoTx

# Domain logic - unchanged regardless of handler
create_order = fn user_id, items ->
  comp do
    result <- DBTransaction.transact(comp do
      # Imagine these are real Ecto operations
      order = %{id: 1, user_id: user_id, items: items}
      return(order)
    end)
    return(result)
  end
end

# Production: real Ecto transactions
create_order.(123, [:item_a, :item_b])
|> EctoTx.with_handler(MyApp.Repo)
|> Comp.run!()
#=> %{id: 1, user_id: 123, items: [:item_a, :item_b]}

# Testing: no database, same domain code
alias Skuld.Effects.DBTransaction.Noop, as: NoopTx

create_order.(123, [:item_a, :item_b])
|> NoopTx.with_handler()
|> Comp.run!()
#=> %{id: 1, user_id: 123, items: [:item_a, :item_b]}
```

### Query

Backend-agnostic data queries with pluggable handlers:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Query, Throw}

# Define a query module (in real code, this would have actual implementations)
defmodule MyQueries do
  def find_user(%{id: id}), do: %{id: id, name: "User #{id}"}
end

# Runtime: dispatch to actual query modules
comp do
  user <- Query.request(MyQueries, :find_user, %{id: 123})
  return(user)
end
|> Query.with_handler(%{MyQueries => :direct})
|> Comp.run!()
#=> %{id: 123, name: "User 123"}

# Test: stub responses
comp do
  user <- Query.request(MyQueries, :find_user, %{id: 456})
  return(user)
end
|> Query.with_test_handler(%{
  Query.key(MyQueries, :find_user, %{id: 456}) => %{id: 456, name: "Stubbed"}
})
|> Throw.with_handler()
|> Comp.run!()
#=> %{id: 456, name: "Stubbed"}
```

### EventAccumulator

Accumulate domain events during computation (built on Writer):

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.EventAccumulator

comp do
  _ <- EventAccumulator.emit(%{type: :user_created, id: 1})
  _ <- EventAccumulator.emit(%{type: :email_sent, to: "user@example.com"})
  return(:ok)
end
|> EventAccumulator.with_handler(output: fn result, events -> {result, events} end)
|> Comp.run!()
#=> {:ok, [%{type: :user_created, id: 1}, %{type: :email_sent, to: "user@example.com"}]}
```

### EffectLogger

Capture effect invocations for replay, resume, and retry:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{EffectLogger, State}

# Capture a log of effects
{{result, log}, _env} = (
  comp do
    x <- State.get()
    _ <- State.put(x + 10)
    y <- State.get()
    return({x, y})
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
#=>     %EffectLogEntry{sig: State, data: %State.Put{value: 10}, value: :ok, state: :executed},
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
    return({x, y})
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
# Example (requires Ecto and a configured Repo)
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.EctoPersist

comp do
  user <- EctoPersist.insert(User.changeset(%User{}, %{name: "Alice"}))
  order <- EctoPersist.insert(Order.changeset(%Order{}, %{user_id: user.id}))
  return({user, order})
end
|> EctoPersist.with_handler(MyApp.Repo)
|> Comp.run!()
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

## License

MIT License - see [LICENSE](LICENSE) for details.
