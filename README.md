# Skuld

[![Test](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml)

Evidence-passing algebraic effects for Elixir.

Skuld is a clean, efficient implementation of algebraic effects using evidence-passing
style with CPS (continuation-passing style) for control effects. It provides scoped
handlers, coroutines via Yield, and composable effect stacks.

## Features

- **Evidence-passing style**: Handlers are looked up directly from the environment, avoiding pattern matching on effect signatures
- **CPS for control effects**: Enables proper support for control flow effects like Yield and Throw
- **Scoped handlers**: Handlers are automatically installed/restored with proper cleanup
- **Composable**: Multiple effects can be stacked and composed naturally
- **No Freer/Hefty split**: Single unified `comp` macro for all effects

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
import Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{State, Reader, Writer, Throw, Yield}

# Define a computation using the comp macro
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

# Run with handlers installed
{result, _env} =
  example()
  |> Reader.with_handler(:my_config)
  |> State.with_handler(0)
  |> Writer.with_handler()
  |> Comp.run()
```

## Effects

### State

Mutable state within a computation:

```elixir
defcomp counter() do
  n <- State.get()
  _ <- State.put(n + 1)
  return(n)
end

{result, _} =
  counter()
  |> State.with_handler(0)
  |> Comp.run()
# result = 0
```

### Reader

Read-only environment:

```elixir
defcomp greet() do
  name <- Reader.ask()
  return("Hello, #{name}!")
end

{result, _} =
  greet()
  |> Reader.with_handler("World")
  |> Comp.run()
# result = "Hello, World!"
```

### Writer

Accumulating output:

```elixir
defcomp logging() do
  _ <- Writer.tell("step 1")
  _ <- Writer.tell("step 2")
  return(:done)
end

{{result, log}, _} =
  logging()
  |> Writer.with_handler()
  |> Comp.run()
# result = :done
# log = ["step 1", "step 2"]
```

### Throw

Error handling:

```elixir
defcomp might_fail(x) do
  if x < 0 do
    Throw.throw({:error, "negative value"})
  else
    return(x * 2)
  end
end

defcomp with_recovery() do
  result <- Throw.catch_error(
    might_fail(-1),
    fn error -> return({:recovered, error}) end
  )
  return(result)
end

{result, _} = with_recovery() |> Comp.run()
# result = {:recovered, {:error, "negative value"}}
```

### Yield

Coroutine-style suspension and resumption:

```elixir
defcomp generator() do
  _ <- Yield.yield(1)
  _ <- Yield.yield(2)
  _ <- Yield.yield(3)
  return(:done)
end

# Collect all yielded values
{:done, result, yields, _} =
  generator()
  |> Yield.with_handler()
  |> Yield.collect()
# result = :done
# yields = [1, 2, 3]

# Or drive with a custom function
{:done, _, _} =
  generator()
  |> Yield.with_handler()
  |> Yield.run_with_driver(fn yielded ->
    IO.puts("Got: #{yielded}")
    {:continue, :ok}
  end)
```

### FxList

Effectful list operations:

```elixir
defcomp process_all(items) do
  results <- FxList.fx_map(items, fn item ->
    comp do
      count <- State.get()
      _ <- State.put(count + 1)
      return(item * 2)
    end
  end)
  return(results)
end

{result, _} =
  process_all([1, 2, 3])
  |> State.with_handler(0)
  |> Comp.run()
# result = [2, 4, 6]
```

> **Note**: For large iteration counts (10,000+), use `Yield`-based coroutines instead
> of `FxList` for better performance. See the FxList module docs for details.

## Architecture

Skuld uses evidence-passing style where:

1. **Handlers** are stored in the environment as functions
2. **Effects** look up their handler and call it directly
3. **CPS** enables control effects (Yield, Throw) to manipulate continuations
4. **Scoped handlers** automatically manage handler installation/cleanup

This avoids the performance overhead of pattern matching on effect signatures
and enables efficient composition of multiple effects.

## Comparison with Freyja

Skuld is a cleaner alternative to Freyja:

| Aspect | Freyja | Skuld |
|--------|--------|-------|
| Effect representation | Freer monad + Hefty algebras | Evidence-passing CPS |
| Control effects | Hefty (higher-order) | Direct CPS |
| Handler dispatch | Pattern matching on signatures | Direct map lookup |
| Macro system | `con` + `hefty` | Single `comp` |

## License

MIT License - see [LICENSE](LICENSE) for details.
