# The Decider Pattern

<!-- nav:header:start -->
[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:header:end -->

Event-sourced domain logic where the core decision is a pure function.
Effects handle state and persistence; the decider stays plain Elixir.

## The pure decider

A decider is a function `(command, state) -> events`. It's pure: given
a command and current state, it produces a list of events. No database,
no side effects.

```elixir
defmodule BankAccount do
  def decide(%OpenAccount{initial_balance: balance}, nil) do
    if balance < 0 do
      [{:error, :negative_balance}]
    else
      [%AccountOpened{balance: balance}]
    end
  end

  def decide(%Deposit{amount: amount}, state) do
    [%AmountDeposited{amount: amount}]
  end

  def decide(%Withdraw{amount: amount}, state) do
    if amount > state.balance do
      [{:error, :insufficient_funds}]
    else
      [%AmountWithdrawn{amount: amount}]
    end
  end
end
```

## Evolve state from events

```elixir
def evolve(nil, %AccountOpened{balance: balance}), do: %{balance: balance}
def evolve(state, %AmountDeposited{amount: amount}), do: %{state | balance: state.balance + amount}
def evolve(state, %AmountWithdrawn{amount: amount}), do: %{state | balance: state.balance - amount}
```

## Putting it together

Load state, call the pure decider, evolve, and persist:

```elixir
defcomp handle(cmd) do
  state <- State.get()
  events = BankAccount.decide(cmd, state)

  case events do
    [{:error, reason}] ->
      {:error, reason}

    _ ->
      _ <- Writer.tell(:events, events)
      new_state = Enum.reduce(events, state, &evolve/2)
      _ <- State.put(new_state)
      {:ok, new_state}
  end
end
```

`decide` and `evolve` are plain Elixir functions — testable without
effects. `State` and `Writer` handle persistence.

## Streaming commands

Separate the pipeline into `decide` and `evolve` phases. `Brook.flat_map`
runs each command through the pure decider and flattens the resulting
event lists into a single stream. A second `Brook.map` persists each
event — with automatic N+1 batching via `Query.Contract`.

### Event store contract

Define `deffetch` operations for persisting events:

```elixir
defmodule EventStore do
  use Skuld.Query

  deffetch evolve(event :: term()) :: :ok
end
```

### The pipeline

```elixir
def process_stream(stream) do
  stream
  |> Brook.flat_map(fn cmd ->
    comp do
      state <- State.get()
      BankAccount.decide(cmd, state)
    end
  end)
  |> Brook.map(&EventStore.evolve/1, concurrency: 4)
end
```

The caller handles the source and sink:

```elixir
commands
|> Brook.from_enum()
|> process_stream()
|> Brook.to_list()
```

`flat_map` runs `decide` concurrently and flattens the event lists.
The second phase maps each event through `evolve` — and because
`evolve` is a `deffetch` operation under `FiberPool`, the
scheduler batches concurrent calls for the executor:

```elixir
commands
|> Brook.from_enum()
|> process_stream()
|> Brook.to_list()
|> Skuld.Query.with_executor(EventStore, EventStore.EctoExecutor)
|> State.with_handler(%{balance: 0})
|> Writer.with_handler([], tag: :errors)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

The decider stays pure. The pipeline demonstrates composition:
`Brook` for streaming, `flat_map` for flattening, `Query` for
batched persistence — each a separate concern, combined into
a single computation.

<!-- nav:footer:start -->

---

[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:footer:end -->
