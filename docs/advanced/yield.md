# Yield (Coroutines)

Yield enables coroutine-style suspension and resumption. A computation
can yield a value and pause, waiting for the caller to provide a
response before continuing. This is the foundation for all of Skuld's
advanced control-flow capabilities - FiberPool, Channel, Brook,
EffectLogger, and AsyncComputation all build on Yield.

> **Note:** You don't need Yield for most applications. The foundational
> effects (State, Reader, Throw, DB, Port, etc.) cover common patterns
> without coroutines. Yield is for when you need cooperative scheduling,
> interactive protocols, or serializable workflows.

## Basic usage

```elixir
generator = comp do
  _ <- Yield.yield(1)
  _ <- Yield.yield(2)
  _ <- Yield.yield(3)
  :done
end
```

A computation that yields is like a generator - it produces values one
at a time and pauses between each one.

### Collecting all values

```elixir
generator
|> Yield.with_handler()
|> Yield.collect()
#=> {:done, :done, [1, 2, 3], _env}
```

`Yield.collect/1` runs the computation to completion, gathering every
yielded value into a list.

### Driving with a function

```elixir
generator
|> Yield.with_handler()
|> Yield.run_with_driver(fn yielded, _data ->
  IO.puts("Got: #{yielded}")
  {:continue, :ok}
end)
# Prints: Got: 1, Got: 2, Got: 3
#=> {:done, :done, _env}
```

`run_with_driver/2` gives you control at each suspension point. The
driver function receives the yielded value and returns
`{:continue, response}` to resume the computation with `response` as
the result of the yield call.

## Operations

- `Yield.yield(value)` - suspend the computation, yielding `value`.
  Returns whatever value the driver/responder provides on resume.

## Handler

```elixir
Yield.with_handler()
```

The handler converts `yield` calls into `Suspend` values that the
runner infrastructure (`collect`, `run_with_driver`, `Comp.run`) can
act on.

## Yield.respond - internal yield handling

`Yield.respond/2` catches yields inside a computation and provides
responses, similar to how `Throw.catch_error/2` catches throws. This
lets you handle yield requests within the computation itself.

```elixir
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
```

The responder function receives the yielded value and returns a
computation whose result becomes the yield's return value.

### Responders can use effects

```elixir
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
```

### Unhandled yields propagate

If the responder doesn't handle a yield, it can re-yield to propagate
upward:

```elixir
comp do
  Yield.respond(
    comp do
      x <- Yield.yield(:handled)
      y <- Yield.yield(:not_handled)
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

## Catch clause with Yield

The `catch` clause supports `{Yield, pattern}` for intercepting
yields, providing a cleaner alternative to `Yield.respond/2`:

```elixir
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

Clause order determines composition: consecutive same-module clauses
are grouped, and each module switch creates a new interceptor layer
(first group innermost).

## Use cases

- **Generators** - produce sequences lazily, one value at a time
- **Interactive protocols** - yield prompts, receive responses
  (wizard flows, CLI interactions, LLM conversation loops)
- **Cooperative scheduling** - the basis for FiberPool's fiber scheduler
- **Serializable workflows** - combined with EffectLogger, yields
  become serialization points where a computation can be persisted
  and cold-resumed later (see [EffectLogger](effect-logger.md))
