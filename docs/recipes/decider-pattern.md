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
effects. `State` and `Writer` handle persistence:

```elixir
handle(%Deposit{amount: 100})
|> State.with_handler(%{balance: 50})
|> Writer.with_handler([], tag: :events, output: fn r, events -> {r, Enum.reverse(events)} end)
|> Throw.with_handler()
|> Comp.run!()
# => {{:ok, %{balance: 150}}, [%AmountDeposited{amount: 100}]}
```

The pattern separates pure domain logic (decide, evolve) from effectful
infrastructure (state, event log). The effects handle the plumbing; the
decider stays a plain Elixir module with no dependencies.

<!-- nav:footer:start -->

---

[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:footer:end -->
