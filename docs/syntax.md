# Syntax In Depth

The [Getting Started](getting-started.md) guide covered the basics: `comp`
blocks, `<-` binds, auto-lifting, handlers, and `defcomp`. This page
covers the full syntax in detail.

## The `<-` bind

The effectful bind `<-` supports pattern matching on the left-hand side:

```elixir
comp do
  {:ok, user} <- fetch_user(id)
  %{name: name} <- get_profile(user)
  name
end
```

When the pattern matches, the bound variables are available in subsequent
expressions. When it doesn't match, Skuld throws a `%MatchFailed{}`
error containing the unmatched value. This is analogous to how a failed
pattern match in Elixir raises a `MatchError`, but within the effect
system.

Without an `else` clause, an unmatched `<-` bind will propagate as a
Throw effect, which needs a Throw handler installed or the computation
will fail.

## The `else` clause

The `else` clause handles pattern match failures from `<-` bindings,
similar to Elixir's `with/else`:

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

When a `<-` binding's pattern doesn't match, the unmatched value is
passed to the `else` clauses. If an `else` clause matches, its body
becomes the computation's result. If no `else` clause matches, the value
is re-thrown.

The `else` clause uses the Throw effect internally, so a Throw handler
must be installed (either via `|> Throw.with_handler()` or via `catch`).

### else with multiple binds

The `else` clause handles failures from *any* `<-` bind in the body:

```elixir
comp do
  {:ok, a} <- step_one()
  {:ok, b} <- step_two(a)
  {:ok, c} <- step_three(b)
  {a, b, c}
else
  {:error, reason} -> {:failed, reason}
end
```

If any step returns `{:error, reason}` instead of `{:ok, _}`, the else
clause catches it. This is a common pattern for chaining fallible
operations - very similar to `with`.

## The `catch` clause

The `catch` clause has two forms: **interception** and **installation**.

### Interception: `{Module, pattern}`

Tagged patterns intercept effects locally:

```elixir
comp do
  result <- risky_operation()
  process(result)
catch
  {Throw, :timeout} -> {:error, :timed_out}
  {Throw, {:validation, reason}} -> {:error, {:invalid, reason}}
end
```

When `risky_operation()` throws `:timeout`, the catch clause intercepts
it and returns `{:error, :timed_out}` instead. The computation continues
normally with that value.

The tag (e.g., `Throw`, `Yield`) determines which effect's interception
mechanism is used:

- `{Throw, pattern}` intercepts thrown errors (via `Throw.catch_error/2`)
- `{Yield, pattern}` intercepts yielded values (via `Yield.respond/2`)

### Default re-dispatch

When catch clauses don't include a catch-all pattern, unhandled values
are automatically re-dispatched - re-thrown for Throw, re-yielded for
Yield:

```elixir
comp do
  result <- risky_operation()
  result
catch
  {Throw, :timeout} -> :default_value    # only catches :timeout
  # other throws automatically re-thrown
end
```

To handle all values, add a catch-all:

```elixir
catch
  {Throw, :timeout} -> :default_value
  {Throw, other} -> Throw.throw({:wrapped, other})  # explicit re-throw with context
end
```

### Intercepting yields

Yield interception responds to suspended computations:

```elixir
comp do
  config <- Yield.yield(:need_config)
  process(config)
catch
  {Yield, :need_config} -> %{default: true}
  {Yield, other} -> Yield.yield(other)           # re-yield unhandled
end
```

When the computation yields `:need_config`, the catch clause provides
`%{default: true}` as the response and the computation continues.

### Installation: `Module -> config`

Bare module patterns install handlers for the body, as an alternative to
piping with `|> Module.with_handler(...)`:

```elixir
comp do
  x <- State.get()
  config <- Reader.ask()
  {x, config}
catch
  State -> 0                    # install State handler with initial value 0
  Reader -> %{timeout: 5000}   # install Reader handler with config value
end
|> Comp.run!()
#=> {0, %{timeout: 5000}}
```

This calls `Module.__handle__(computation, config)` for each clause.
It's especially useful when the handler config is computed or when you
want handlers visually close to their usage:

```elixir
comp do
  id <- Fresh.fresh_uuid()
  _ <- Writer.tell("Generated: #{id}")
  id
catch
  Fresh -> :uuid7              # use UUID7 handler
  Writer -> []                 # start with empty log
end
```

All built-in effects support installation via `__handle__/2`. See each
effect's documentation for the config format.

### Mixed interception and installation

Both forms work together in the same `catch` block:

```elixir
comp do
  result <- risky_operation()
  result
catch
  {Throw, :recoverable} -> {:ok, :fallback}  # interception
  State -> 0                                   # installation
  Throw -> nil                                 # installation
end
```

The interception (`{Throw, :recoverable}`) catches locally, while the
installations provide the handlers that the computation and interception
code run within.

### Clause grouping and composition order

Consecutive same-module clauses are grouped into a single handler.
Each time the module changes, a new interception layer is created.
First group is innermost, last group is outermost:

```elixir
catch
  {Throw, :a} -> ...   # group 1 (inner)
  {Throw, :b} -> ...   # group 1 (inner)
  {Yield, :x} -> ...   # group 2 (middle)
  {Throw, :c} -> ...   # group 3 (outer)
end
```

This layering matters: a throw from the Yield handler in group 2 would
be caught by group 3, not group 1. You have full control over which
layer catches what.

## Combining `else` and `catch`

Both clauses can be used together. `else` must come before `catch`:

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

- `else` handles pattern match failures from `<-` bindings in the body
- `catch` wraps everything, catching throws from both the body *and* the
  else handler

This means a throw from an else clause handler is caught by the catch
clause, but not vice versa.

## Auto-lifting details

Skuld auto-lifts plain values to computations in these positions:

- **Final expression** in a `comp` block: `x * 2` becomes `Comp.pure(x * 2)`
- **`if` without `else`**: the `nil` from the missing branch is lifted
- **`case` / `cond` branches**: non-computation results are lifted
- **`else` clause bodies**: return values are lifted
- **`catch` clause bodies**: return values are lifted

Auto-lifting does *not* apply to:

- **`<-` right-hand side**: this must be a computation (an effect call or
  another `comp` block)
- **Arguments to effect operations**: these are plain Elixir values

The rule of thumb: anywhere Skuld expects a computation and gets a plain
value, it wraps it in `Comp.pure`. You rarely need to think about this -
it's designed to make effectful code feel like regular Elixir.

## `defcomp` and `defcompp`

`defcomp` defines a public effectful function, `defcompp` defines a
private one:

```elixir
defmodule MyDomain do
  use Skuld.Syntax

  # Public effectful function
  defcomp fetch_user_data(user_id) do
    user <- Port.request!(Users, :find, [user_id])
    profile <- Port.request!(Profiles, :find, [user_id])
    {user, profile}
  end

  # Private effectful function
  defcompp validate_user(user) do
    if user.active, do: user, else: Throw.throw(:inactive_user)
  end
end
```

Both support `else` and `catch` clauses:

```elixir
defcomp safe_fetch(id) do
  {:ok, user} <- fetch_user(id)
  user
else
  {:error, _} -> nil
catch
  {Throw, _} -> nil
end
```

`defcomp` is equivalent to wrapping the function body in `comp do ... end`.
The function returns a computation - it doesn't execute the effects.
Callers compose it with `<-` or pipe it to handlers.

## Cancelling suspended computations

A computation can suspend (via Yield or other control effects), returning
a `%Suspend{}` struct. Skuld supports cancellation with guaranteed
cleanup - the `leave_scope` chain runs, allowing effects to release
resources:

```elixir
# Run until suspension
{%Suspend{value: :waiting} = suspend, env} = computation |> Comp.run()

# Cancel instead of resuming - triggers cleanup
{%Cancelled{reason: :user_cancelled}, _env} =
  Comp.cancel(suspend, env, :user_cancelled)
```

`Comp.cancel/3` creates a `%Cancelled{}` result and invokes the cleanup
chain, ensuring effects like database connections or locks are properly
released. This is used internally by `AsyncComputation.cancel/1` and
`Yield.run_with_driver/2`.
