# Error Handling & Resources

<!-- nav:header:start -->
[< State & Environment](state-environment.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [Value Generation >](value-generation.md)
<!-- nav:header:end -->

## Throw

Typed error handling within computations. Throw is the primary way to
handle errors in Skuld - it replaces the need for `raise`/`rescue` with
composable, interceptable error values.

### Basic usage

```elixir
comp do
  x = -1
  _ <- if x < 0, do: Throw.throw({:error, "negative"})
  x * 2
catch
  {Throw, err} -> {:recovered, err}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:recovered, {:error, "negative"}}
```

### Elixir exception interop

Elixir's `raise`, `throw`, and `exit` are automatically converted to
Throw effects inside computations:

```elixir
comp do
  raise ArgumentError, "oops"
catch
  {Throw, %{kind: :error, payload: %ArgumentError{message: msg}}} ->
    {:caught, msg}
end
|> Throw.with_handler()
|> Comp.run!()
#=> {:caught, "oops"}
```

The converted error is a map with `:kind` (`:error`, `:throw`, or
`:exit`), `:payload` (the exception/value), and `:stacktrace`.

When using `Comp.run!/1`, unhandled Elixir exceptions are re-raised
with their original stacktrace, so debuggability is preserved.

### `try_catch` for Either-style results

`Throw.try_catch/1` wraps a computation and returns `{:ok, value}` or
`{:error, error}`:

```elixir
Throw.try_catch(comp do
  raise ArgumentError, "bad input"
end)
|> Throw.with_handler()
|> Comp.run!()
#=> {:error, %ArgumentError{message: "bad input"}}

Throw.try_catch(comp do
  _ <- Throw.throw(:my_error)
  :ok
end)
|> Throw.with_handler()
|> Comp.run!()
#=> {:error, :my_error}
```

### `IThrowable` protocol for domain exceptions

For domain exceptions that represent expected failures, implement
`IThrowable` to get cleaner error values from `try_catch`:

```elixir
defmodule MyApp.NotFoundError do
  defexception [:entity, :id]

  @impl true
  def message(%{entity: entity, id: id}), do: "#{entity} not found: #{id}"
end

defimpl Skuld.Comp.IThrowable, for: MyApp.NotFoundError do
  def unwrap(%{entity: entity, id: id}), do: {:not_found, entity, id}
end

Throw.try_catch(comp do
  raise MyApp.NotFoundError, entity: :user, id: 123
end)
|> Throw.with_handler()
|> Comp.run!()
#=> {:error, {:not_found, :user, 123}}
```

### Handler

```elixir
Throw.with_handler(opts \\ nil)
```

The Throw handler is typically installed without arguments. It processes
thrown values and, for `Comp.run!/1`, converts unhandled throws to
exceptions.

## Bracket

Safe resource acquisition and guaranteed cleanup, analogous to
`try/finally`.

### `bracket` - Acquire, use, release

```elixir
comp do
  result <- Bracket.bracket(
    # Acquire
    comp do
      _ <- State.put(:acquired)
      :resource
    end,
    # Release (always runs, even on error)
    fn _resource ->
      comp do
        _ <- State.put(:released)
        :ok
      end
    end,
    # Use
    fn resource ->
      {:used, resource}
    end
  )
  final_state <- State.get()
  {result, final_state}
end
|> State.with_handler(:init)
|> Comp.run!()
#=> {{:used, :resource}, :released}
```

The release function always runs, whether the use function completes
normally, throws, or yields.

### `finally` - Simpler cleanup

When you don't need to pass a resource between acquire and release:

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

## Debugging

Skuld preserves stacktraces through CPS execution. When something goes
wrong, you see your source file and line number, not Skuld internals:

```elixir
defmodule MyDomain do
  use Skuld.Syntax

  defcomp process(data) do
    _ <- if data == :bad, do: raise ArgumentError, "invalid data"
    {:ok, data}
  end
end

MyDomain.process(:bad)
|> Throw.with_handler()
|> Comp.run!()
#=> ** (ArgumentError) invalid data
#=>     my_domain.ex:5: MyDomain.process/1
```

Different Elixir error types are handled consistently:

- `raise` - re-raised as the original exception type with original
  stacktrace
- `throw` - wrapped in `%UncaughtThrow{value: thrown_value}`
- `exit` - wrapped in `%UncaughtExit{reason: exit_reason}`

Skuld's own `Throw.throw/1` produces `%ThrowError{}` when unhandled,
which includes the thrown value for debugging.

<!-- nav:footer:start -->

---

[< State & Environment](state-environment.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [Value Generation >](value-generation.md)
<!-- nav:footer:end -->
