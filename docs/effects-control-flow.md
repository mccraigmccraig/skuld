# Effects: Control Flow

## Throw

Error handling with the `catch` clause using tagged patterns `{Throw, pattern}`:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Throw

comp do
  x = -1
  _ <- if x < 0, do: Throw.throw({:error, "negative"})  # nil auto-lifted when false
  x * 2
catch
  {Throw, err} -> {:recovered, err}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:recovered, {:error, "negative"}}
```

The `catch` clause with `{Throw, pattern}` desugars to `Throw.catch_error/2`:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Throw

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
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Throw

# Helper functions that raise/throw
defmodule Risky do
  def boom!, do: raise "oops!"
  def throw_ball!, do: throw(:ball)
end

# Elixir raise is caught and converted - even as the first expression
comp do
  Risky.boom!()
catch
  {Throw, %{kind: :error, payload: %RuntimeError{message: msg}}} -> {:caught_raise, msg}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:caught_raise, "oops!"}

# Elixir throw is also converted
comp do
  Risky.throw_ball!()
catch
  {Throw, %{kind: :throw, payload: value}} -> {:caught_throw, value}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:caught_throw, :ball}
```

The converted error is a map with `:kind`, `:payload`, and `:stacktrace` keys,
allowing you to handle different error types uniformly.

## Pattern Matching with Else

The `else` clause handles pattern match failures in `<-` bindings. Since `else`
uses the Throw effect internally, you need a Throw handler:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Throw

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

## Combining Else and Catch

Both clauses can be used together. The `else` must come before `catch`:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Throw

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
  {Throw, err} -> {:caught_throw, err}
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
  {Throw, err} -> {:caught_throw, err}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:match_failed, :negative}
```

The semantic ordering is `catch(else(body))`, meaning:
- `else` handles pattern match failures from the main computation
- `catch` handles throws from both the main computation AND the else handler

## Bracket

Safe resource acquisition and cleanup (like try/finally):

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Bracket, State}

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
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Bracket, State}

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

## Yield

Coroutine-style suspension and resumption:

```elixir
use Skuld.Syntax
alias Skuld.Effects.Yield

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
|> Yield.run_with_driver(fn yielded, _data ->
  IO.puts("Got: #{yielded}")
  {:continue, :ok}
end)
# Prints: Got: 1, Got: 2, Got: 3
#=> {:done, :done, _env}
```

## Yield.respond - Internal Yield Handling

`Yield.respond/2` catches yields inside a computation and provides responses, similar
to how `Throw.catch_error/2` catches throws. This enables handling yield requests
within the computation itself rather than requiring an external driver:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Yield, State}

# Handle yields internally with a responder function
comp do
  result <- Yield.respond(
    comp do
      x <- Yield.yield(:get_x)
      y <- Yield.yield(:get_y)
      x + y
    end,
    fn
      :get_x -> Comp.pure(10)
      :get_y -> Comp.pure(20)
    end
  )
  result
end
|> Yield.with_handler()
|> Comp.run!()
#=> 30

# Responder can use effects (State, Reader, etc.)
comp do
  Yield.respond(
    comp do
      x <- Yield.yield(:get_state)
      _ <- Yield.yield({:add, 10})
      y <- Yield.yield(:get_state)
      {x, y}
    end,
    fn
      :get_state -> State.get()
      {:add, n} -> State.modify(&(&1 + n))
    end
  )
end
|> State.with_handler(5)
|> Yield.with_handler()
|> Comp.run!()
#=> {5, 15}

# Unhandled yields propagate to outer handler (re-yield)
comp do
  Yield.respond(
    comp do
      x <- Yield.yield(:handled)
      y <- Yield.yield(:not_handled)  # propagates up
      x + y
    end,
    fn
      :handled -> Comp.pure(10)
      other -> Yield.yield(other)  # re-yield unhandled
    end
  )
end
|> Yield.with_handler()
|> Comp.run()
#=> {%Comp.Suspend{value: :not_handled, resume: resume}, _env}
#   Call resume.(20) to complete: {30, _env}
```

Use cases for `Yield.respond`:
- **Nested coroutine patterns** - Handle some yields locally while propagating others
- **Internal request/response loops** - Build protocols within a computation
- **Composing yield-based computations** - Layer handlers for different yield types

## Catch Clause with Yield

The `catch` clause supports `{Yield, pattern}` for intercepting yields, providing a
cleaner alternative to explicit `Yield.respond/2` calls:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Yield

# Using catch to intercept yields
comp do
  x <- Yield.yield(:get_x)
  y <- Yield.yield(:get_y)
  x + y
catch
  {Yield, :get_x} -> return(10)
  {Yield, :get_y} -> return(20)
end
|> Yield.with_handler()
|> Comp.run!()
#=> 30
```

You can combine Throw and Yield interception in the same catch clause:

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Yield, Throw}

comp do
  config <- Yield.yield(:need_config)
  result <- risky_operation(config)
  result
catch
  {Yield, :need_config} -> return(%{default: true})
  {Throw, :timeout} -> return(:retry_later)
  {Throw, err} -> Throw.throw({:wrapped, err})
end
```

Clause order determines composition: consecutive same-module clauses are grouped,
and each module switch creates a new interceptor layer (first group innermost).
