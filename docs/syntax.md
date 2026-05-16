# Syntax In Depth

<!-- nav:header:start -->
[< Getting Started](getting-started.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Quick Reference >](quick-reference.md)
<!-- nav:header:end -->

## `comp do` blocks

```elixir
comp do
  x <- effect()             # effectful bind — run effect, bind result
  {:ok, y} = expr           # pure pattern match (left of = is the pattern)
  z = expr                  # pure assignment
  value                     # last expression is auto-lifted
end
```

All expressions except the last must be `<-` or `=`. The final
expression is implicitly wrapped in `Comp.pure/1`. Use `return(value)`
outside of `comp` blocks or for final expressions that need an explicit
lift:

```elixir
Comp.return(42)             # explicit pure computation
def get_answer, do: return(42)  # in defcomp, shorthand for Comp.return/1
```

## `<-` bind

The `<-` operator runs an effectful computation and binds its result:

```elixir
comp do
  user <- Repo.get(User, id)    # user is the unwrapped value
  name <- Reader.ask()           # reads from Reader handler
  {user, name}
end
```

Desugars to `Comp.bind(effect(), fn result -> ... end)`.

## Pattern matching with `<-`

```elixir
comp do
  {:ok, user} <- Repo.get(User, id)    # match on result tuple
  {:ok, count} = {:ok, 42}             # pure pattern match (= not <-)
end
```

Use `<-` for effectful operations, `=` for pure values.

## `else` clause

Handle pattern match failures in `<-`:

```elixir
comp do
  {:ok, user} <- Repo.get(User, id)
else
  {:error, :not_found} -> {:error, :not_found}
  {:error, reason} -> Throw.throw(reason)
end
```

## `catch` clause

Intercept effects or install handlers inline:

```elixir
comp do
  result <- risky_computation()
  result
catch
  {Throw, :not_found} -> :default_value          # intercept specific error
  State -> 0                                      # install handler (State.with_handler(0))
  Reader -> %{timeout: 5000}                      # install handler (Reader.with_handler(...))
end
```

The `{Effect, pattern}` form intercepts the effect. The bare `Effect`
form installs a handler. First clause innermost, last outermost.

## `defcomp`

Define a function that returns a computation:

```elixir
defmodule MyApp.Users do
  use Skuld.Syntax

  defcomp get_user(id) do
    {:ok, user} <- Repo.get(User, id)
    {:ok, user}
  end
end
```

Equivalent to:

```elixir
def get_user(id) do
  comp do
    {:ok, user} <- Repo.get(User, id)
    {:ok, user}
  end
end
```

## `defcallback` (with Port.EffectfulFacade)

Define a typed port operation:

```elixir
defmodule MyApp.Users do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback get_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()}
end
```

Generates a function `get_user/1` returning `computation(User.t() | {:error, term()})`.

## Auto-lifting

Bare values at the end of a `comp` block are automatically lifted:

```elixir
comp do
  x <- State.get()
  x * 2    # auto-lifted — no return() needed
end
```

`if` without `else` also auto-lifts:

```elixir
comp do
  x <- State.get()
  _ <- if x > 5, do: Writer.tell(:big)   # nil auto-lifted when false
  x
end
```

## Running

```elixir
Comp.run!(comp)           # extract value, raises on Throw/Suspend
{result, env} = Comp.run(comp)  # returns raw result + env
```

## Handling effects

Piping through `with_handler`:

```elixir
comp
|> State.with_handler(0)
|> Reader.with_handler(%{})
|> Throw.with_handler()
|> Comp.run!()
```

Handler order is independent (each manages its own effect). `EffectLogger` must be innermost to record all effects.

<!-- nav:footer:start -->

---

[< Getting Started](getting-started.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Quick Reference >](quick-reference.md)
<!-- nav:footer:end -->
