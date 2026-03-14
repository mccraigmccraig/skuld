# Syntax

The `comp` macro is the primary way to write effectful code in Skuld. It provides
a clean syntax for sequencing effectful operations, handling failures, and locally
intercepting effects.

## Computations

### The Computation Type

In Skuld, a **computation** is a suspended effectful program - a lazy description of
work that only executes when explicitly run. This is fundamentally different from
eager evaluation where calling a function immediately performs its side effects.

```elixir
# This doesn't run anything yet - it returns a computation
computation = comp do
  count <- State.get()
  _ <- State.put(count + 1)
  count
end

# The computation is just data until we run it
computation
|> State.with_handler(0)
|> Comp.run!()
#=> {0, %{}}
```

This lazy evaluation enables powerful patterns:
- **Composition**: Build complex computations from simpler ones
- **Handler installation**: Add effect handlers before execution
- **Reuse**: Run the same computation multiple times with different handlers
- **Testing**: Use test handlers (pure, in-memory) with production code

### Running Computations

Skuld provides two functions for running computations:

**`Comp.run!/1`** - Runs a computation, extracting just the result value:

```elixir
State.get()
|> State.with_handler(42)
|> Comp.run!()
#=> {42, %{}}
```

**`Comp.run/1`** - Runs a computation, returning both the result and the final environment:

```elixir
{result, env} = State.get()
|> State.with_handler(42)
|> Comp.run()
#=> {%Skuld.Comp.Done{value: {42, %{}}}, %{...}}
```

Use `Comp.run/1` when you need access to the environment after execution, or when
working with suspendable computations (like those using Yield).

### Cancelling Suspended Computations

A computation can suspend (via Yield or other control effects), returning a
`%Suspend{}` struct instead of completing. Unlike, say, JavaScript Promises (which
cannot be cancelled), **Skuld computations support cancellation with guaranteed
cleanup** - the `leave_scope` chain runs, allowing effects to release resources
(close connections, release locks, etc.):

```elixir
alias Skuld.Comp
alias Skuld.Comp.{Suspend, Cancelled}

# A computation with scoped cleanup
computation =
  Yield.yield(:waiting)
  |> Comp.scoped(fn env ->
    IO.puts("Entering scope")
    finally_k = fn result, e ->
      IO.puts("Cleanup called with: #{inspect(result.__struct__)}")
      {result, e}
    end
    {env, finally_k}
  end)
  |> Yield.with_handler()

# Run until suspension
{%Suspend{value: :waiting} = suspend, env} = Comp.run(computation)
# Prints: Entering scope

# Cancel instead of resuming - triggers cleanup
{%Cancelled{reason: :user_cancelled}, _final_env} =
  Comp.cancel(suspend, env, :user_cancelled)
# Prints: Cleanup called with: Skuld.Comp.Cancelled
```

The `Comp.cancel/3` function:
- Creates a `%Cancelled{reason: reason}` result
- Invokes the `leave_scope` chain for proper effect cleanup
- Returns `{%Cancelled{}, final_env}`

This is used internally by `AsyncComputation.cancel/1` and `Yield.run_with_driver/2`
(via `{:cancel, reason}` driver return) to ensure effects can clean up when
computations are cancelled.

## The comp Block

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

## Effectful Binds and Pure Matches

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

## Auto-Lifting

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

## The else Clause

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

## The catch Clause

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
- `{Throw, pattern}` -> `Throw.catch_error/2`
- `{Yield, pattern}` -> `Yield.respond/2`

**Composition order:** Consecutive same-module clauses are grouped into one
handler. Each time the module changes, a new interceptor layer is added. First
group is innermost, last group is outermost:

```elixir
catch
  {Throw, :a} -> ...   # -> group 1 (inner)
  {Throw, :b} -> ...   # -/
  {Yield, :x} -> ...   # --- group 2 (middle)
  {Throw, :c} -> ...   # --- group 3 (outer)
```

This gives you full control over interception layering - a throw from the Yield
handler in group 2 would be caught by group 3, not group 1.

**Default re-dispatch:** Patterns without a catch-all automatically re-dispatch
unhandled values (re-throw for Throw, re-yield for Yield).

## Handler Installation via Catch

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

## Combining else and catch

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

## defcomp

For defining named effectful functions, use `defcomp`:

```elixir
defmodule MyDomain do
  use Skuld.Syntax

  defcomp fetch_user_data(user_id) do
    user <- Port.request!(Users, :find, [user_id])
    profile <- Port.request!(Profiles, :find, [user_id])
    {user, profile}
  end
end
```

This is equivalent to `def fetch_user_data(user_id), do: comp do ... end`.
