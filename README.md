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

Add `skuld` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:skuld, "~> 0.1.0"}
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
