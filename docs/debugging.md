# Debugging

Skuld preserves stacktraces and exception types, so debugging feels natural. When
something goes wrong, you see your source file and line number at the top of the
stacktrace, just like regular Elixir code.

## Elixir Exceptions in Computations

When Elixir's `raise`, `throw`, or `exit` occurs inside a computation, Skuld captures
the original exception with its stacktrace. If you use `Comp.run!/1`, the original
exception is re-raised with its original stacktrace:

```elixir
defmodule MyDomain do
  use Skuld.Syntax

  defcomp process(data) do
    # This raise will show MyDomain.process in the stacktrace
    _ <- if data == :bad, do: raise ArgumentError, "invalid data"
    {:ok, data}
  end
end

MyDomain.process(:bad)
|> Throw.with_handler()
|> Comp.run!()
#=> ** (ArgumentError) invalid data
#=>     my_domain.ex:5: MyDomain.process/1
#=>     ...
```

The stacktrace points directly to your code, not to Skuld internals. This works for:
- `raise` -> re-raised as the original exception type
- `throw` -> wrapped in `%UncaughtThrow{value: thrown_value}`
- `exit` -> wrapped in `%UncaughtExit{reason: exit_reason}`

## Skuld's Throw Effect

When you use `Throw.throw/1` (Skuld's effect-based error handling), unhandled throws
become `%ThrowError{}` exceptions:

```elixir
comp do
  _ <- Throw.throw(:not_found)
  :ok
end
|> Throw.with_handler()
|> Comp.run!()
#=> ** (Skuld.Comp.ThrowError) Computation threw: :not_found
```

To handle throws within the computation, use the `catch` clause:

```elixir
comp do
  _ <- Throw.throw(:not_found)
  :ok
catch
  {Throw, :not_found} -> {:error, :not_found}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:error, :not_found}
```

## Caught Elixir Exceptions

If you catch Elixir exceptions with a `catch` clause, they arrive as maps with full
context:

```elixir
comp do
  raise ArgumentError, "oops"
catch
  {Throw, %{kind: :error, payload: exception, stacktrace: stacktrace}} ->
    {:caught, Exception.message(exception)}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:caught, "oops"}
```

The map contains:
- `:kind` - `:error`, `:throw`, or `:exit`
- `:payload` - the exception struct, thrown value, or exit reason
- `:stacktrace` - the original stacktrace from where the error occurred

## try_catch for Either-Style Results

`Throw.try_catch/1` wraps a computation and returns Either-style `{:ok, value}` or
`{:error, error}` results. It automatically unwraps caught exceptions for cleaner
pattern matching:

```elixir
# Raised exceptions become {:error, exception_struct}
Throw.try_catch(comp do
  raise ArgumentError, "bad input"
end)
|> Throw.with_handler()
|> Comp.run!()
#=> {:error, %ArgumentError{message: "bad input"}}

# Elixir throw becomes {:error, {:thrown, value}}
Throw.try_catch(comp do
  throw(:some_value)
end)
|> Throw.with_handler()
|> Comp.run!()
#=> {:error, {:thrown, :some_value}}

# Skuld Throw.throw passes through unchanged
Throw.try_catch(comp do
  _ <- Throw.throw(:my_error)
  :ok
end)
|> Throw.with_handler()
|> Comp.run!()
#=> {:error, :my_error}
```

## IThrowable Protocol for Domain Exceptions

For domain exceptions that represent expected failures (validation errors, not-found,
permission denied), implement the `Skuld.Comp.IThrowable` protocol to get cleaner
error values from `try_catch`:

```elixir
defmodule MyApp.NotFoundError do
  defexception [:entity, :id]

  @impl true
  def message(%{entity: entity, id: id}), do: "#{entity} not found: #{id}"
end

defimpl Skuld.Comp.IThrowable, for: MyApp.NotFoundError do
  def unwrap(%{entity: entity, id: id}), do: {:not_found, entity, id}
end

# Now try_catch returns the unwrapped value
Throw.try_catch(comp do
  raise MyApp.NotFoundError, entity: :user, id: 123
end)
|> Throw.with_handler()
|> Comp.run!()
#=> {:error, {:not_found, :user, 123}}

# Enables clean pattern matching on domain errors
case result do
  {:ok, user} -> handle_user(user)
  {:error, {:not_found, :user, id}} -> handle_not_found(id)
  {:error, %ArgumentError{}} -> handle_bad_input()
end
```

By default (without an `IThrowable` implementation), exceptions are returned as-is,
which is appropriate for unexpected errors where you want the full exception for
debugging.
