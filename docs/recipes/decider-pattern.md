# The Decider Pattern

<!-- nav:header:start -->
[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:header:end -->

Event-sourced domain logic where the core decision is a pure function.
`Command` provides the dispatch; handlers manage state and persistence.

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

## Wiring with effects

The computation loads state, dispatches to the decider via `Command`,
evolves state from the resulting events, and persists:

```elixir
defcomp handle(cmd) do
  state <- State.get()
  events <- Command.execute(cmd)

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

The `Command` handler just calls the pure decider:

```elixir
computation
|> Command.with_handler(fn cmd ->
  Comp.bind(State.get(), fn state ->
    BankAccount.decide(cmd, state)
  end)
end)
|> State.with_handler(%{balance: 50})
|> Writer.with_handler([], tag: :events)
|> Throw.with_handler()
|> Comp.run!()
```

The decider is a pure Elixir module — testable with plain function
calls. The computation manages state and persistence via effects.
`Command` provides the dispatch from operation to implementation,
so the pattern composes naturally with other effects in the stack.

<!-- nav:footer:start -->

---

[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:footer:end -->
