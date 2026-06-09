# Yield

<!-- nav:header:start -->
[< FxList](fxlist.md) | [Up: Foundational Effects](state-reader-writer.md) | [Index](../../README.md) | [Hexagonal Architecture >](../recipes/hexagonal-architecture.md)
<!-- nav:header:end -->

Yield suspends a computation mid-flight, returning control to the caller
with a value. The caller can later resume the computation with a response.

This is the primitive that bridges the foundational effects to the
coroutine system. `Coroutine`, `FiberPool`, `AsyncCoroutine`, and
`EffectLogger` all build on top of `Yield`.

## Basic usage

```elixir
defcomp ask_name do
  name <- Yield.yield(:get_name)      # suspend, return :get_name
  {:ok, "Hello, #{name}!"}
end
```

Running it:

```elixir
{%Comp.ExternalSuspend{value: :get_name, resume: resume}, env} =
  ask_name() |> Yield.with_handler() |> Comp.run()

# Later, when we have a name:
{result, _env} = resume.("Alice")
# result == {:ok, "Hello, Alice!"}
```

The computation pauses at `Yield.yield(:get_name)`. The caller gets an
`ExternalSuspend` with the yielded value and a `resume` function. Calling
`resume.(value)` continues the computation from where it left off.

## Operations

```elixir
value <- Yield.yield(:ask_user)       # suspend with a value
value <- Yield.yield(:ask_user, data) # suspend with data payload
Yield.respond(:answer)                # respond to source (bidirectional)
```

## Patterns

### Multi-step wizards

```elixir
defcomp wizard do
  name <- Yield.yield(:get_name)
  email <- Yield.yield(:get_email)
  {:ok, %{name: name, email: email}}
end
```

### Collect pattern

`Yield.collect` feeds a stream of inputs into a yielding computation,
collecting the final result:

```elixir
Yield.collect(wizard(), ["Alice", "alice@example.com"])
# => {:ok, %{name: "Alice", email: "alice@example.com"}}
```

### Feed pattern

`Yield.feed` links two yielding computations — the output of one feeds
into the yield of another:

```elixir
Yield.feed(producer(), consumer())
```

## Handler

```elixir
computation |> Yield.with_handler()
```

`Yield.with_handler` converts `Yield.yield` calls into `ExternalSuspend`
sentinels. Handler order relative to other effects doesn't matter — each
handler manages its own effect independently.

<!-- nav:footer:start -->

---

[< FxList](fxlist.md) | [Up: Foundational Effects](state-reader-writer.md) | [Index](../../README.md) | [Hexagonal Architecture >](../recipes/hexagonal-architecture.md)
<!-- nav:footer:end -->
