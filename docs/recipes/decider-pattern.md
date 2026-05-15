# The Decider Pattern

<!-- nav:header:start -->
[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:header:end -->

Event-sourced domain logic using `Command` + `Writer`. The pattern
separates decision-making from event persistence — commands produce
events, events are persisted, and state is derived from the event stream.

## Core idea

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

## Putting it together with effects

`Command` dispatches to the decider. `Writer` collects events:

```elixir
defcomp handle_command(cmd) do
  state <- Reader.ask()                              # load state
  events <- Command.execute({BankAccount, :decide, cmd, state})  # decide
  _ <- Writer.tell(:events, events)                  # collect events
  new_state = Enum.reduce(events, state, &evolve/2)
  _ <- Reader.local(fn _ -> new_state end, fn ->     # update state
    {:ok, _} <- State.put(new_state)                 # persist state
    events
  end)
end
```

The decider is pure. The effectful code handles loading state,
persisting events, and updating projections. Swap handlers to test:

```elixir
handle_command(%Deposit{amount: 100})
|> Reader.with_handler(%{balance: 50})
|> Command.with_handler(fn {mod, fun, cmd, state} -> apply(mod, fun, [cmd, state]) end)
|> Writer.with_handler([], tag: :events, output: fn r, events -> {r, Enum.reverse(events)} end)
|> State.with_handler(nil)
|> Throw.with_handler()
|> Comp.run!()
# => {[{:ok, %{balance: 150}}], [%AmountDeposited{amount: 100}]}
```

<!-- nav:footer:start -->

---

[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:footer:end -->
