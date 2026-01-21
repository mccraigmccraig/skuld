# Skuld

[![Test](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/skuld.svg)](https://hex.pm/packages/skuld)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/skuld/)

Evidence-passing Algebraic Effects for Elixir.

Skuld is a clean, efficient implementation of Algebraic Effects using evidence-passing
style with CPS (continuation-passing style) for control effects. It provides scoped
handlers, composable effect stacks, and a library of useful effects.

Algebraic effects add an architectural layer between pure and side-effecting code:
instead of just pure functions and side-effecting functions, you have pure functions,
effectful functions, and side-effecting handlers. Domain code is written with effects
but remains pure - the same code runs with test handlers (pure, in-memory) or
production handlers (real I/O). This enables clean separation of concerns,
property-based testing, and effect logging for resume and replay.

Skuld's library of effects aims to provide primitives broad enough that most domain
computations can use effectful operations instead of side-effecting ones. Here are
some common side-effecting operations and their effectful equivalents:

| Side-effecting operation        | Effectful equivalent         |
|---------------------------------|------------------------------|
| Configuration / environment     | Reader                       |
| Process dictionary              | State, Writer                |
| Random values                   | Random                       |
| Generating IDs (UUIDs)          | Fresh                        |
| Async tasks / parallel work     | Async, Parallel, AtomicState |
| Run effects from LiveView       | AsyncComputation             |
| Database transactions           | DBTransaction                |
| Database queries                | Query                        |
| Ecto Repo operations            | ChangesetPersist             |
| Decider pattern                 | Command, EventAccumulator    |
| Tracing, replay & resume        | EffectLogger                 |
| Raising exceptions              | Throw                        |
| Resource cleanup (try/finally)  | Bracket                      |
| Control flow                    | Yield                        |
| Lists of effectful computations | FxList, FxFasterList         |

## Contents

- [Features](#features)
- [Installation](#installation)
- [Demo Application](#demo-application)
- [Quick Start](#quick-start)
- [Syntax](#syntax)
  - [The comp Block](#the-comp-block)
  - [Effectful Binds and Pure Matches](#effectful-binds-and-pure-matches)
  - [Auto-Lifting](#auto-lifting)
  - [The else Clause](#the-else-clause)
  - [The catch Clause](#the-catch-clause)
- [Effects](#effects)
  - [State & Environment](#state--environment)
    - [State](#state)
    - [Reader](#reader)
    - [Writer](#writer)
    - [Multiple Independent Contexts (Tagged Usage)](#multiple-independent-contexts-tagged-usage)
    - [Scoped State Transformation](#scoped-state-transformation)
  - [Control Flow](#control-flow)
    - [Throw](#throw)
    - [Pattern Matching with Else](#pattern-matching-with-else)
    - [Combining Else and Catch](#combining-else-and-catch)
    - [Bracket](#bracket)
    - [Yield](#yield)
  - [Collection Iteration](#collection-iteration)
    - [FxList](#fxlist)
    - [FxFasterList](#fxfasterlist)
  - [Value Generation](#value-generation)
    - [Fresh](#fresh)
    - [Random](#random)
  - [Concurrency](#concurrency)
    - [AtomicState](#atomicstate)
    - [Async](#async)
    - [Parallel](#parallel)
    - [AsyncComputation](#asynccomputation)
  - [Persistence & Data](#persistence--data)
    - [DBTransaction](#dbtransaction)
    - [Query](#query)
    - [Command](#command)
    - [EventAccumulator](#eventaccumulator)
    - [ChangesetPersist](#changesetpersist)
  - [Replay & Logging](#replay--logging)
    - [EffectLogger](#effectlogger)
- [Property-Based Testing](#property-based-testing)
- [Architecture](#architecture)
- [Comparison with Freyja](#comparison-with-freyja)
- [Performance](#performance)
- [License](#license)

## Features

- **Evidence-passing style**: Handlers are looked up directly from a map in the
  dynamic environment
- **CPS for control effects**: Enables proper support for control flow effects
  like Yield and Throw
- **Scoped handlers**: Handlers are automatically installed/restored with proper
  cleanup
- **Composable**: Multiple effects can be stacked and composed naturally
- **Single type**: Single unified `computation` type and `comp` macro for all
  effectful code - ideal for dynamic languages
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

## Syntax

The `comp` macro is the primary way to write effectful code in Skuld. It provides
a clean syntax for sequencing effectful operations, handling failures, and locally
intercepting effects.

### The comp Block

A `comp` block sequences effectful operations, similar to Haskell's `do` notation
or F#'s computation expressions:

```elixir
comp do
  # Sequence of expressions
  x <- effect_operation()
  y = pure_computation(x)
  another_effect(y)
end
```

The block returns a **computation** - a suspended effectful program that only
executes when run with `Comp.run!/1` or `Comp.run/1`. This lazy evaluation
enables composition and handler installation before execution.

### Effectful Binds and Pure Matches

The `comp` block supports two binding forms:

**Effectful bind (`<-`)** - Extracts the result of an effectful computation:

```elixir
comp do
  count <- State.get()        # Run State.get effect, bind result to count
  name <- Reader.ask()        # Run Reader.ask effect, bind result to name
  {count, name}
end
```

**Pure match (`=`)** - Standard Elixir pattern matching on pure values:

```elixir
comp do
  data <- fetch_data()
  %{name: name, age: age} = data    # Pure destructuring
  formatted = "#{name} (#{age})"    # Pure computation
  formatted
end
```

Both forms support pattern matching. Match failures from either form can be
handled by the `else` clause, which receives the unmatched value.

### Auto-Lifting

Plain values are automatically lifted to computations, enabling ergonomic patterns:

```elixir
comp do
  x <- State.get()
  x * 2                           # Plain value auto-lifted to Comp.pure(x * 2)
end

comp do
  _ <- if should_log?, do: Writer.tell("logging")   # nil auto-lifted when false
  :done
end
```

This means you can use `if` without `else`, `cond`, `case`, and other Elixir
constructs naturally - any non-computation value becomes `Comp.pure(value)`.

### The else Clause

The `else` clause handles pattern match failures in `<-` bindings, similar to
Elixir's `with` expression:

```elixir
comp do
  {:ok, user} <- fetch_user(id)
  {:ok, profile} <- fetch_profile(user.id)
  {user, profile}
else
  {:error, :not_found} -> {:error, "User not found"}
  {:error, :profile_missing} -> {:error, "Profile not found"}
  other -> {:error, {:unexpected, other}}
end
|> Throw.with_handler()
|> Comp.run!()
```

When a `<-` binding fails to match, the unmatched value is passed to the `else`
clauses. Without an `else` clause, match failures throw a `%MatchFailed{}` error.

**Note:** The `else` clause uses the Throw effect internally, so you need a
Throw handler installed.

### The catch Clause

The `catch` clause installs scoped effect interceptors using tagged patterns
`{Module, pattern}`. This provides local handling of effects like Throw and Yield:

**Catching throws:**

```elixir
comp do
  result <- risky_operation()
  process(result)
catch
  {Throw, :timeout} -> {:error, :timed_out}
  {Throw, {:validation, reason}} -> {:error, {:invalid, reason}}
  {Throw, err} -> Throw.throw({:wrapped, err})   # Re-throw with context
end
```

**Intercepting yields:**

```elixir
comp do
  config <- Yield.yield(:need_config)
  process(config)
catch
  {Yield, :need_config} -> return(%{default: true})
  {Yield, other} -> Yield.yield(other)           # Re-yield unhandled
end
```

**Combining multiple effects:**

```elixir
comp do
  config <- Yield.yield(:get_config)
  result <- might_fail(config)
  result
catch
  {Yield, :get_config} -> return(load_default_config())
  {Throw, :recoverable} -> return(:fallback)
  {Throw, err} -> Throw.throw(err)
end
```

The `catch` clause desugars to calls to `Module.intercept/2`:
- `{Throw, pattern}` → `Throw.catch_error/2`
- `{Yield, pattern}` → `Yield.respond/2`

**Composition order:** Consecutive same-module clauses are grouped into one
handler. Each time the module changes, a new interceptor layer is added. First
group is innermost, last group is outermost:

```elixir
catch
  {Throw, :a} -> ...   # ─┐ group 1 (inner)
  {Throw, :b} -> ...   # ─┘
  {Yield, :x} -> ...   # ─── group 2 (middle)
  {Throw, :c} -> ...   # ─── group 3 (outer)
```

This gives you full control over interception layering - a throw from the Yield
handler in group 2 would be caught by group 3, not group 1.

**Default re-dispatch:** Patterns without a catch-all automatically re-dispatch
unhandled values (re-throw for Throw, re-yield for Yield).

### Handler Installation via Catch

In addition to interception with `{Module, pattern}`, the `catch` clause supports
**handler installation** using bare module patterns. This provides an alternative
to piping with `|> Module.with_handler(...)`:

```elixir
comp do
  x <- State.get()
  config <- Reader.ask()
  {x, config}
catch
  State -> 0                    # Install State handler with initial value 0
  Reader -> %{timeout: 5000}    # Install Reader handler with config value
end
|> Comp.run!()
#=> {0, %{timeout: 5000}}
```

**Syntax distinction:**
- `{Module, pattern} -> body` = **interception** (calls `Module.intercept/2`)
- `Module -> config` = **installation** (calls `Module.__handle__/2`)

This syntax reduces cognitive dissonance by keeping handler installation "inside"
the computation block. It's especially useful when the handler config is computed
or when you want handlers closer to their usage:

```elixir
comp do
  id <- Fresh.fresh_uuid()
  _ <- Writer.tell("Generated: #{id}")
  id
catch
  Fresh -> :uuid7              # Use UUID7 handler
  Writer -> []                 # Start with empty log
end
```

**Mixed interception and installation** work together:

```elixir
comp do
  result <- risky_operation()
  result
catch
  {Throw, :recoverable} -> {:ok, :fallback}  # Interception
  State -> 0                                   # Installation
  Throw -> nil                                 # Installation (no config needed)
end
```

**Supported effects:** All built-in effects implement `__handle__/2`. See each
effect's module documentation for the config format it accepts.

### Combining else and catch

Both clauses can be used together. The `else` must come before `catch`:

```elixir
comp do
  {:ok, x} <- might_fail_or_mismatch()
  x * 2
else
  {:error, reason} -> {:match_failed, reason}
catch
  {Throw, err} -> {:caught_throw, err}
end
```

The semantic ordering is `catch(else(body))`:
- `else` handles pattern match failures from `<-` bindings
- `catch` wraps the else-handled computation, catching throws from both

### defcomp

For defining named effectful functions, use `defcomp`:

```elixir
defmodule MyDomain do
  use Skuld.Syntax

  defcomp fetch_user_data(user_id) do
    user <- Query.request(Users, :find, %{id: user_id})
    profile <- Query.request(Profiles, :find, %{user_id: user_id})
    {user, profile}
  end
end
```

This is equivalent to `def fetch_user_data(user_id), do: comp do ... end`.

## Effects

All examples below assume the following setup (paste once into IEx):

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{
  State, Reader, Writer, Throw, Yield,
  FxList, FxFasterList,
  Fresh, Random, AtomicState, Async, Parallel, Bracket, Query, Command, 
  EventAccumulator, EffectLogger,
  DBTransaction, ChangesetPersist, ChangeEvent
}
alias Skuld.Effects.DBTransaction.Noop, as: NoopTx
alias Skuld.Effects.DBTransaction.Ecto, as: EctoTx
```

### State & Environment

#### State

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

#### Reader

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

#### Writer

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

#### Multiple Independent Contexts (Tagged Usage)

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

#### Scoped State Transformation

Effects that use scoped state (State, Writer, Reader, Fresh, Random, Query, AtomicState)
support `:output` and `:suspend` options for transforming values at scope boundaries:

**`:output` - Transform result when leaving scope**

When a computation completes, the `:output` function receives the result and final
state, returning a transformed result. This lets you include effect state in the
return value:

```elixir
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

**`:suspend` - Decorate Suspend values when yielding**

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
options compose—inner handlers decorate first, outer handlers see and can further
modify the result.

EffectLogger uses this mechanism automatically when `:decorate_suspend` is true
(the default), attaching the current log to `Suspend.data[EffectLogger]` for
access by AsyncComputation callers.

### Control Flow

#### Throw

Error handling with the `catch` clause using tagged patterns `{Throw, pattern}`:

```elixir
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

#### Pattern Matching with Else

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

#### Combining Else and Catch

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

#### Bracket

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

#### Yield

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

#### Yield.respond - Internal Yield Handling

`Yield.respond/2` catches yields inside a computation and provides responses, similar
to how `Throw.catch_error/2` catches throws. This enables handling yield requests
within the computation itself rather than requiring an external driver:

```elixir
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

#### Catch Clause with Yield

The `catch` clause supports `{Yield, pattern}` for intercepting yields, providing a
cleaner alternative to explicit `Yield.respond/2` calls:

```elixir
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

### Collection Iteration

#### FxList

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

#### FxFasterList

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

### Value Generation

#### Fresh

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

#### Random

Generate random values with three handler modes:

```elixir
# Production: uses Erlang :rand module
comp do
  f <- Random.random()              # float in [0, 1)
  i <- Random.random_int(1, 100)    # integer in range
  elem <- Random.random_element([:a, :b, :c])
  shuffled <- Random.shuffle([1, 2, 3, 4])
  {f, i, elem, shuffled}
end
|> Random.with_handler()
|> Comp.run!()
#=> {0.723..., 42, :b, [3, 1, 4, 2]}

# Testing: deterministic with seed (reproducible)
comp do
  a <- Random.random()
  b <- Random.random_int(1, 10)
  {a, b}
end
|> Random.with_seed_handler(seed: {42, 123, 456})
|> Comp.run!()
#=> {0.234..., 7}  # same result every time with this seed

# Testing: fixed sequence for specific scenarios
comp do
  a <- Random.random()
  b <- Random.random()
  {a, b}
end
|> Random.with_fixed_handler(values: [0.0, 1.0])
|> Comp.run!()
#=> {0.0, 1.0}  # cycles when exhausted
```

### Concurrency

#### AtomicState

Thread-safe state for concurrent contexts. Unlike the regular State effect which
stores state in `env.state` (copied when forking to new processes), AtomicState
uses external storage (Agent) that can be safely accessed from multiple processes:

```elixir
# Basic usage - similar to State but with atomic guarantees
comp do
  _ <- AtomicState.put(0)
  _ <- AtomicState.modify(&(&1 + 1))
  AtomicState.get()
end
|> AtomicState.with_agent_handler(0)
|> Comp.run!()
#=> 1

# Compare-and-swap for lock-free coordination
comp do
  _ <- AtomicState.put(10)
  r1 <- AtomicState.cas(10, 20)  # succeeds: current == expected
  r2 <- AtomicState.cas(10, 30)  # fails: current is 20, not 10
  final <- AtomicState.get()
  {r1, r2, final}
end
|> AtomicState.with_agent_handler(0)
|> Comp.run!()
#=> {:ok, {:conflict, 20}, 20}

# Multiple independent states with tags
comp do
  _ <- AtomicState.put(:counter, 0)
  _ <- AtomicState.put(:cache, %{})
  _ <- AtomicState.modify(:counter, &(&1 + 1))
  _ <- AtomicState.modify(:cache, &Map.put(&1, :key, "value"))
  counter <- AtomicState.get(:counter)
  cache <- AtomicState.get(:cache)
  {counter, cache}
end
|> AtomicState.with_agent_handler(0, tag: :counter)
|> AtomicState.with_agent_handler(%{}, tag: :cache)
|> Comp.run!()
#=> {1, %{key: "value"}}

# Testing: State-backed handler (no Agent processes)
comp do
  _ <- AtomicState.modify(&(&1 + 10))
  AtomicState.get()
end
|> AtomicState.with_state_handler(5)
|> Comp.run!()
#=> 15
```

Operations: `get/1`, `put/2`, `modify/2`, `atomic_state/2` (get-and-update), `cas/3`

#### Async

Structured concurrent computation with async/await and boundaries:

```elixir
# Basic async/await within a boundary
comp do
  result <- Async.boundary(
    comp do
      # Start concurrent tasks
      h1 <- Async.async(comp do :result_1 end)
      h2 <- Async.async(comp do :result_2 end)
      
      # Await both results
      r1 <- Async.await(h1)
      r2 <- Async.await(h2)
      {r1, r2}
    end
  )
  result
end
|> Async.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> {:result_1, :result_2}
```

**Boundaries** provide structured concurrency—all tasks must be awaited or explicitly
handled before the boundary exits:

```elixir
# Unawaited tasks throw by default
comp do
  Async.boundary(
    comp do
      _ <- Async.async(comp do :ignored end)  # Not awaited!
      :done
    end
  )
catch
  {Throw, err} -> {:caught, err}
end
|> Async.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> {:caught, {:unawaited_tasks, 1}}

# Custom on_unawaited handler - ignore unawaited tasks
comp do
  Async.boundary(
    comp do
      _ <- Async.async(comp do :ignored end)
      :done
    end,
    fn result, _unawaited -> result end  # Just return result
  )
end
|> Async.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> :done
```

**Task failures** are caught and returned as errors:

```elixir
comp do
  Async.boundary(
    comp do
      h <- Async.async(comp do raise "boom!" end)
      Async.await(h)
    end
  )
end
|> Async.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> {:error, {:task_failed, %{kind: :error, payload: %RuntimeError{...}, ...}}}
```

**Cancelling tasks** explicitly removes them from the boundary's unawaited set:

```elixir
comp do
  Async.boundary(
    comp do
      h1 <- Async.async(comp do :approach_a_result end)
      h2 <- Async.async(comp do :approach_b_result end)
      
      # Use first result, cancel the other
      result <- Async.await(h1)
      _ <- Async.cancel(h2)
      result
    end
  )
end
|> Async.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> :approach_a_result
```

**Timeouts** let you limit how long to wait for a task:

```elixir
# await_with_timeout waits with a deadline
comp do
  result <- Async.boundary(
    comp do
      h <- Async.async(comp do :fast_result end)
      Async.await_with_timeout(h, 5000)  # 5 second timeout
    end
  )
  result
end
|> Async.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> {:ok, :fast_result}

# timeout/2 is a convenience that wraps boundary + async + await_with_timeout
comp do
  result <- Async.timeout(5000, comp do :quick_work end)
  case result do
    {:ok, value} -> value
    {:error, :timeout} -> :gave_up
  end
end
|> Async.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> :quick_work
```

**Testing handler** runs tasks sequentially for deterministic tests:

```elixir
comp do
  Async.boundary(
    comp do
      h <- Async.async(comp do :sequential end)
      Async.await(h)
    end
  )
end
|> Async.with_sequential_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> :sequential
```

Operations: `boundary/2`, `async/1`, `await/1`, `cancel/1`

> **Note**: Async computations run on the same BEAM node. Closures cannot be
> serialized across nodes, so distributed async is not supported.

#### Parallel

Simple fork-join concurrency with built-in boundaries. Unlike `Async`, each operation
is self-contained with automatic task management:

```elixir
# Run multiple computations in parallel, get all results
comp do
  Parallel.all([
    comp do %{id: 1, name: "Alice"} end,
    comp do %{id: 2, name: "Bob"} end,
    comp do %{id: 3, name: "Carol"} end
  ])
end
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}, %{id: 3, name: "Carol"}]

# Race: return first to complete, cancel others
comp do
  Parallel.race([
    comp do :slow_result end,
    comp do :fast_result end
  ])
end
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> :slow_result or :fast_result (first to complete wins)

# Map over items in parallel
comp do
  Parallel.map([1, 2, 3], fn id ->
    comp do %{id: id, name: "User #{id}"} end
  end)
end
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [%{id: 1, name: "User 1"}, %{id: 2, name: "User 2"}, %{id: 3, name: "User 3"}]
```

**Error handling**: Task failures are caught. For `all/1` and `map/2`, the first
failure returns `{:error, {:task_failed, reason}}`. For `race/1`, failures are
ignored unless all tasks fail.

**Testing handler** runs tasks sequentially for deterministic tests:

```elixir
comp do
  Parallel.all([comp do :a end, comp do :b end])
end
|> Parallel.with_sequential_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [:a, :b]
```

Operations: `all/1`, `race/1`, `map/2`

#### AsyncComputation

Run effectful computations from non-effectful code (e.g., LiveView), bridging yields,
throws, and results back via messages:

```elixir
# Build a computation with handlers
computation =
  comp do
    name <- Yield.yield(:get_name)
    email <- Yield.yield(:get_email)
    {:ok, %{name: name, email: email}}
  end
  |> Reader.with_handler(%{tenant_id: "t-123"})

# Start async - returns immediately, first response via message
{:ok, runner} = Skuld.AsyncComputation.start(computation, tag: :create_user)

# Start sync - blocks until first yield/result/throw (for fast-yielding computations)
{:ok, runner, {:yield, :get_name, data}} =
  Skuld.AsyncComputation.start_sync(computation, tag: :create_user, timeout: 5000)
# `data` contains any decorations from scoped effects (e.g., EffectLogger log)

# Messages arrive as {tag, status, value} or {tag, status, value, data}:
# - {:create_user, :yield, :get_name, data}  <- computation yielded (data has effect decorations)
# - {:create_user, :result, value}           <- computation completed
# - {:create_user, :throw, error}            <- computation threw
# - {:create_user, :stopped, reason}         <- cancelled

# Resume async - returns immediately, next response via message
Skuld.AsyncComputation.resume(runner, "Alice")

# Resume sync - blocks until next yield/result/throw
case Skuld.AsyncComputation.resume_sync(runner, "Alice", timeout: 5000) do
  {:yield, next_prompt, data} -> # computation yielded again
  {:result, value} -> # computation completed
  {:throw, error} -> # computation threw
  {:error, :timeout} -> # timed out
end

# Cancel if needed
Skuld.AsyncComputation.cancel(runner)
```

**LiveView example:**

```elixir
def handle_event("start_wizard", _params, socket) do
  computation =
    comp do
      name <- Yield.yield(%{step: 1, prompt: "Enter name"})
      email <- Yield.yield(%{step: 2, prompt: "Enter email"})
      {:ok, %{name: name, email: email}}
    end
    |> MyApp.with_domain_handlers()

  {:ok, runner} = Skuld.AsyncComputation.start(computation, tag: :wizard)
  {:noreply, assign(socket, runner: runner, step: nil)}
end

def handle_info({:wizard, :yield, %{step: step, prompt: prompt}, _data}, socket) do
  {:noreply, assign(socket, step: step, prompt: prompt)}
end

def handle_info({:wizard, :result, {:ok, user}}, socket) do
  {:noreply, socket |> assign(user: user, runner: nil) |> put_flash(:info, "Created!")}
end

def handle_info({:wizard, :throw, error}, socket) do
  {:noreply, socket |> assign(runner: nil) |> put_flash(:error, inspect(error))}
end

def handle_event("submit_step", %{"value" => value}, socket) do
  Skuld.AsyncComputation.resume(socket.assigns.runner, value)
  {:noreply, socket}
end
```

**Key points:**

- Adds `Throw.with_handler/1` and `Yield.with_handler/1` automatically
- Exceptions in computations become `{tag, :throw, %{kind: :error, payload: exception}}` messages
- Linked by default (use `link: false` for unlinked)
- Yield messages include `data` containing decorations from scoped effects (e.g., `data[EffectLogger]` has the current log when using `EffectLogger.with_logging/2`)
- Use this for non-effectful callers; use `Async` effect when inside a computation

Operations: `start/2`, `start_sync/2`, `resume/2`, `resume_sync/3`, `cancel/1`

### Persistence & Data

#### DBTransaction

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

#### Query

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

#### Command

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
(Fresh, ChangesetPersist, EventAccumulator, etc.) internally. This enables a clean
separation between command dispatch and command implementation.

#### EventAccumulator

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

#### ChangesetPersist

Changeset persistence as effects (requires Ecto):

```elixir
# Production: real database operations via Ecto handler
comp do
  user <- ChangesetPersist.insert(User.changeset(%User{}, %{name: "Alice"}))
  order <- ChangesetPersist.insert(Order.changeset(%Order{}, %{user_id: user.id}))
  {user, order}
end
|> ChangesetPersist.Ecto.with_handler(MyApp.Repo)
|> Comp.run!()
```

For testing, use the test handler to stub responses and record calls:

```elixir
# Define a simple schema for testing
defmodule User do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :name, :string
  end

  def changeset(user, attrs) do
    user |> cast(attrs, [:name]) |> validate_required([:name])
  end
end

# Test handler applies changeset changes and records all operations
comp do
  user <- ChangesetPersist.insert(User.changeset(%User{}, %{name: "Alice"}))
  _ <- ChangesetPersist.update(User.changeset(user, %{name: "Bob"}))
  user
end
|> ChangesetPersist.Test.with_handler(&ChangesetPersist.Test.default_handler/1)
|> Comp.run!()
#=> {%User{name: "Alice"}, [{:insert, %Ecto.Changeset{...}}, {:update, %Ecto.Changeset{...}}]}

# Custom handler for specific test scenarios
changeset = User.changeset(%User{}, %{name: "Test"})

comp do
  user <- ChangesetPersist.insert(changeset)
  user
end
|> ChangesetPersist.Test.with_handler(fn
  %ChangesetPersist.Insert{input: _cs} -> %User{id: "test-id", name: "Stubbed"}
  %ChangesetPersist.Update{input: cs} -> Ecto.Changeset.apply_changes(cs)
end)
|> Comp.run!()
#=> {%User{id: "test-id", name: "Stubbed"}, [{:insert, %Ecto.Changeset{...}}]}
```

> **Note**: ChangesetPersist wraps Ecto Repo operations. See the module docs for
> `insert`, `update`, `delete`, `insert_all`, `update_all`, `delete_all`, and `upsert`.

### Replay & Logging

#### EffectLogger

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
  |> EffectLogger.with_logging(log, allow_divergence: true)
  |> State.with_handler(999)  # Different initial state - allowed with divergence
  |> Comp.run()
)

replayed
#=> {0, 10}  # Same result - values came from log, not from State handler
```

#### Loop Marking and Pruning

For long-running loop-based computations (like LLM conversation loops), the log can
grow unboundedly. Use `mark_loop/1` to mark iteration boundaries - pruning is enabled
by default and happens eagerly after each mark, keeping memory bounded:

```elixir
# Define a recursive computation that processes items
defmodule ProcessLoop do
  use Skuld.Syntax
  alias Skuld.Effects.{State, Writer, EffectLogger}

  defcomp process(items) do
    # Mark the start of each iteration - captures current state for cold resume
    # Pruning happens immediately after this mark executes
    _ <- EffectLogger.mark_loop(ProcessLoop)

    case items do
      [] ->
        State.get()  # Return final count

      [item | rest] ->
        comp do
          count <- State.get()
          _ <- State.put(count + 1)
          _ <- Writer.tell("Processed: #{item}")
          process(rest)
        end
    end
  end
end

# Pruning is enabled by default - log stays bounded during execution
ProcessLoop.process(["a", "b", "c", "d"])
|> EffectLogger.with_logging()  # prune_loops: true is the default
|> State.with_handler(0)
|> Writer.with_handler([])
|> Comp.run()
#=> {{4, %EffectLogger.Log{...}}, _env}
# Log is small - only root mark + last iteration's effects
# Memory never grew beyond O(1 iteration) during execution
```

**Key benefits:**
- **Bounded memory**: Pruning happens eagerly after each `mark_loop`, so memory stays O(current iteration) even for computations that never suspend or complete
- **Cold resume**: State checkpoints are preserved for resuming from serialized logs
- **State validation**: During replay, state consistency is validated against checkpoints

To disable pruning and keep all entries (e.g., for debugging), use `prune_loops: false`:

```elixir
# Keep all entries for debugging
ProcessLoop.process(["a", "b", "c", "d"])
|> EffectLogger.with_logging(prune_loops: false)
|> State.with_handler(0)
|> Writer.with_handler([])
|> Comp.run()
#=> {{4, %EffectLogger.Log{...}}, _env}
```

#### Cold Resume with Yield

When a computation suspends via `Yield`, you can serialize the log and resume later:

```elixir
# Define a computation that yields for user input
defmodule Conversation do
  use Skuld.Syntax
  alias Skuld.Effects.{State, Writer, Yield, EffectLogger}

  defcomp run() do
    _ <- EffectLogger.mark_loop(ConversationLoop)
    count <- State.get()
    _ <- State.put(count + 1)

    # Yield for input, then continue
    input <- Yield.yield({:prompt, "Message #{count}:"})
    _ <- Writer.tell("User said: #{input}")

    run()  # Loop forever, yielding each iteration
  end
end

# First run - suspends at first yield (pruning is enabled by default)
Conversation.run()
|> EffectLogger.with_logging()
|> Yield.with_handler()
|> State.with_handler(0)
|> Writer.with_handler([])
|> Comp.run()
#=> {%Comp.Suspend{value: {:prompt, "Message 0:"}, ...}, env}

# To continue: extract and serialize the log, then cold resume with user's response
# log = EffectLogger.get_log(env) |> EffectLogger.Log.finalize()
# json = Jason.encode!(log)
# cold_log = json |> Jason.decode!() |> EffectLogger.Log.from_json()
# Conversation.run()
# |> EffectLogger.with_resume(cold_log, "Hello!")
# |> Yield.with_handler()
# |> State.with_handler(999)  # State restored from checkpoint, not this value
# |> Writer.with_handler([])
# |> Comp.run()
```

The `with_resume/3` function:
1. Restores `env.state` from the most recent checkpoint in the log
2. Replays completed effects by short-circuiting with logged values
3. Injects the resume value at the Yield suspension point
4. Continues fresh execution after that point

## Property-Based Testing

Algebraic effects enable a powerful testing pattern: **effectful code that runs pure**.
Domain logic written with effects can execute with real database handlers in production
and pure in-memory handlers in tests—enabling property-based testing with thousands
of iterations per second.

### The Pattern

[TodosMcp](https://github.com/mccraigmccraig/skuld/tree/main/todos_mcp) demonstrates
this approach. The domain handlers use effects for all I/O:

```elixir
# Domain logic in Todos.Handlers - uses effects, doesn't perform I/O directly
defcomp handle(%ToggleTodo{id: id}) do
  ctx <- Reader.ask(CommandContext)
  todo <- Repository.get_todo!(ctx.tenant_id, id)  # Query effect
  changeset = Todo.changeset(todo, %{completed: not todo.completed})
  updated <- ChangesetPersist.update(changeset)    # Persist effect
  {:ok, updated}
end
```

The `Run.execute/2` function composes different handler stacks based on mode:

```elixir
# Production: real database
Run.execute(operation, mode: :database, tenant_id: tenant_id)
# -> Query.with_handler(%{Repository.Ecto => :direct})
# -> ChangesetPersist.Ecto.with_handler(Repo)

# Testing: pure in-memory
Run.execute(operation, mode: :in_memory, tenant_id: tenant_id)
# -> Query.with_handler(%{Repository.Ecto => {Repository.InMemory, :delegate}})
# -> InMemoryPersist.with_handler()
```

### Property Tests

With pure handlers, property-based testing becomes trivial. TodosMcp uses standard
`stream_data` with domain-specific generators:

```elixir
# test/todos_mcp/todos/handlers_property_test.exs
use ExUnitProperties

property "ToggleTodo is self-inverse" do
  check all(cmd <- Generators.create_todo(), max_runs: 100) do
    {:ok, original} = create_and_get(cmd)

    {:ok, toggled} = Run.execute(%ToggleTodo{id: original.id}, mode: :in_memory)
    {:ok, restored} = Run.execute(%ToggleTodo{id: original.id}, mode: :in_memory)

    assert restored.completed == original.completed
  end
end

property "CompleteAll only affects incomplete todos" do
  check all(todos <- Generators.todos(max_length: 20)) do
    incomplete_count = Enum.count(todos, &(not &1.completed))
    {:ok, result} = run_with_todos(%CompleteAll{}, todos)
    assert result.updated == incomplete_count
  end
end
```

### Implementing This Pattern

To enable property-based testing in your project:

1. **Structure domain logic with effects** - Use `Query`, `ChangesetPersist`, `Reader`, etc.
   instead of direct Repo calls or process dictionary access.

2. **Create in-memory implementations** - For each effect that touches external state,
   provide a pure alternative. Skuld includes test handlers for common effects:
   - `Query.with_test_handler/2` - Stub query responses
   - `ChangesetPersist.Test.with_handler/2` - Stub persist operations  
   - `Fresh.with_test_handler/2` - Deterministic UUID generation

3. **Write domain-specific generators** - Create StreamData generators for your
   command/query structs and domain entities (see `TodosMcp.Generators`).

4. **Compose handler stacks by mode** - A single `Run.execute/2` entry point that
   switches handlers based on `:mode` option keeps tests and production code aligned.

The key insight is that **no special Skuld support is needed**—the existing handler
composition is already sufficient. Generators are domain-specific (your structs,
your entities), so they belong in your application, not in Skuld.

## Architecture

Skuld uses evidence-passing style where:

1. **Handlers** are stored in the environment as functions
2. **Effects** look up their handler and call it directly
3. **CPS** enables control effects (Yield, Throw) to manipulate continuations
4. **Scoped handlers** automatically manage handler installation/cleanup

## Comparison with Freyja

Skuld was built after [Freyja](https://github.com/mccraigmccraig/freyja) proved to
have significant limitations, including performance issues and requiring two monad
types (`Freer` and `Hefty`), with all the additional complexity and mental load
that imposes. Skuld's client API looks quite similar to Freyja, but the implementation
is very different - Skuld performs better and has a simpler, more coherent API.

| Aspect                | Freyja                       | Skuld                |
|-----------------------|------------------------------|----------------------|
| Effect representation | Freer monad + Hefty algebras | Evidence-passing CPS |
| Computation types     | `Freer` + `Hefty`            | Just `computation`   |
| Control effects       | Hefty (higher-order)         | Direct CPS           |
| Handler lookup        | Search through handler list  | Direct map lookup    |
| Macro system          | `con` + `hefty`              | Single `comp`        |

Skuld's performance advantage comes from avoiding Freer monad object allocation,
continuation queue management, and linear search for handlers.

## Performance

Benchmark comparing Skuld against pure baselines and minimal effect implementations.
Run with `mix run bench/skuld_benchmark.exs`.

**What's being measured:** A loop that increments a counter from 0 to N using
`State.get()` / `State.put(n + 1)` operations. This exercises the core effect
invocation path repeatedly, measuring per-operation overhead.

### Core Benchmark

| Target | Pure/Rec | Monad  | Evf    | Evf/CPS | Skuld/Nest | Skuld/FxFL |
|--------|----------|--------|--------|---------|------------|------------|
| 500    | 4 µs     | 10 µs  | 17 µs  | 17 µs   | 141 µs     | 54 µs      |
| 1000   | 28 µs    | 55 µs  | 56 µs  | 58 µs   | 255 µs     | 166 µs     |
| 2000   | 34 µs    | 78 µs  | 91 µs  | 97 µs   | 558 µs     | 325 µs     |
| 5000   | 82 µs    | 189 µs | 244 µs | 258 µs  | 1.42 ms    | 836 µs     |
| 10000  | 145 µs   | 157 µs | 298 µs | 325 µs  | 2.3 ms     | 960 µs     |

**Implementations compared:**

- **Pure/Rec** - Non-effectful baseline using tail recursion with map state
- **Monad** - Simple state monad (`fn state -> {val, state} end`) with no effect system
- **Evf** - Flat evidence-passing, direct-style (no CPS) - can't support control effects
- **Evf/CPS** - Flat evidence-passing with CPS - isolates CPS overhead (~1.1x vs Evf)
- **Skuld/Nest** - Skuld with nested `Comp.bind` calls (typical usage pattern)
- **Skuld/FxFL** - Skuld with `FxFasterList` iteration (optimized for collections)

### Iteration Strategies

| Target | FxFasterList          | FxList               | Yield                |
|--------|-----------------------|----------------------|----------------------|
| 1000   | 97 µs (0.10 µs/op)    | 200 µs (0.20 µs/op)  | 147 µs (0.15 µs/op)  |
| 5000   | 492 µs (0.10 µs/op)   | 959 µs (0.19 µs/op)  | 762 µs (0.15 µs/op)  |
| 10000  | 1.02 ms (0.10 µs/op)  | 2.71 ms (0.27 µs/op) | 1.52 ms (0.15 µs/op) |
| 50000  | 5.1 ms (0.10 µs/op)   | -                    | 7.58 ms (0.15 µs/op) |
| 100000 | 10.02 ms (0.10 µs/op) | -                    | 14.9 ms (0.15 µs/op) |

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

### Real-World Perspective

These benchmarks represent a **worst-case scenario** where computations do almost
nothing except exercise the effects machinery. In practice, algebraic effects
compose real work — serialization, domain calculations, transcoding — where actual
computation dominates execution time.

For example, JSON encoding a moderate payload takes 10-100µs, and domain validation
or business logic involves similar compute. Compared to Skuld's ~0.1µs per effect
invocation, even dozens of effect operations add negligible overhead to real
workloads. The architectural benefits—testability, composability, separation of
concerns—far outweigh the microsecond-level cost.

## License

MIT License - see [LICENSE](LICENSE) for details.
