# AtomicState

<!-- nav:header:start -->
[< Parallel](parallel.md) | [Up: Effects](parallel.md) | [Index](../../README.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Thread-safe mutable state for concurrent contexts. Unlike the regular
`State` effect (which stores state in `env.state` and is copied when
forking to new processes), AtomicState uses external storage that can
be safely accessed from multiple processes.

Supports both single-state usage and multiple independent states via tags.

## Basic usage

```elixir
use Skuld.Syntax
alias Skuld.Effects.AtomicState

comp do
  _ <- AtomicState.put(0)
  _ <- AtomicState.modify(&(&1 + 1))
  value <- AtomicState.get()
  value
end
|> AtomicState.Agent.with_handler(0)
|> Comp.run!()
#=> 1
```

## Operations

- **`get/0`**, **`get/1`** — Read the current value. With a `tag`, reads the
  value for that specific tagged state.
- **`put/1`**, **`put/2`** — Replace the value. With a `tag`, writes to that
  specific tagged state.
- **`modify/1`**, **`modify/2`** — Apply a function to the current value
  atomically, returning the new value.
- **`atomic_state/1`**, **`atomic_state/2`** — Apply a function `(value -> {result, new_state})`,
  returning `result` while updating the state to `new_state`.
- **`cas/2`**, **`cas/3`** — Compare-and-swap. If the current value equals
  `expected`, replace it with `new` and return `:ok`. Otherwise return
  `{:conflict, current_value}`.

## Tagged states

Use tags to manage multiple independent states within one computation:

```elixir
comp do
  _ <- AtomicState.put(:counter, 0)
  _ <- AtomicState.modify(:counter, &(&1 + 1))
  count <- AtomicState.get(:counter)

  _ <- AtomicState.put(:cache, %{})
  _ <- AtomicState.modify(:cache, &Map.put(&1, :key, "value"))
  cache <- AtomicState.get(:cache)

  {count, cache}
end
|> AtomicState.Agent.with_handler(0, tag: :counter)
|> AtomicState.Agent.with_handler(%{}, tag: :cache)
|> Comp.run!()
#=> {1, %{key: "value"}}
```

Each tag is independent — operations on `:counter` don't affect `:cache`.

## Handlers

- **`AtomicState.Agent.with_handler/2,3`** — Production handler backed by
  an `Agent` process. Provides true atomic operations accessible from
  multiple processes. The Agent is stopped when the handler scope exits.
- **`AtomicState.Sync.with_handler/2,3`** — Test handler using `env.state`
  storage. No Agent processes, deterministic, suitable for single-process
  tests.

Handler options: `tag` (atom, default: `AtomicState`), `output`, `suspend`
(Sync handler only).

## Compare-and-Swap

```elixir
comp do
  _ <- AtomicState.put(10)
  result1 <- AtomicState.cas(10, 20)  # succeeds
  result2 <- AtomicState.cas(10, 30)  # fails — current is 20, not 10
  {result1, result2}
end
|> AtomicState.Agent.with_handler(0)
|> Comp.run!()
#=> {:ok, {:conflict, 20}}
```

## Catch syntax

```elixir
comp do
  _ <- AtomicState.modify(&(&1 + 1))
  AtomicState.get()
end
|> Comp.run!(
  catch:
    AtomicState -> {:agent, 0}                        # Agent handler
    AtomicState -> {:agent, {0, tag: :counter}}        # Agent with tag
    AtomicState -> {:sync, 0}                          # Sync handler
    AtomicState -> {:sync, {0, tag: :counter}}         # Sync with tag
)
```

<!-- nav:footer:start -->

---

[< Parallel](parallel.md) | [Up: Effects](parallel.md) | [Index](../../README.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
