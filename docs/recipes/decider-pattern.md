# The Decider Pattern

<!-- nav:header:start -->
[< Hexagonal Architecture](hexagonal-architecture.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [Handler Stacks >](handler-stacks.md)
<!-- nav:header:end -->

The [Decider pattern](https://thinkbeforecoding.com/post/2021/12/17/functional-event-sourcing-decider)
is a functional approach to event-sourced domain logic. It separates
domain behaviour into three pure functions:

1. **Decide** - interpret a command against current state, produce events
2. **Evolve** - apply events to state to produce new state
3. **Persist** - store the events and/or updated state

Skuld's Command and EventAccumulator effects map directly to this
pattern, keeping the decide/evolve logic pure and effectful while
persistence is handled by the handler stack.

## The pattern

```
Command → Decide(state, command) → Events
Events  → Evolve(state, events)  → New State
Events  → Persist(events)        → Side Effects
```

## Example: a shopping cart

### Domain events and commands

```elixir
defmodule Cart.Events do
  defmodule ItemAdded do
    defstruct [:cart_id, :item_id, :quantity, :price]
  end

  defmodule ItemRemoved do
    defstruct [:cart_id, :item_id]
  end

  defmodule CartCheckedOut do
    defstruct [:cart_id, :total]
  end
end

defmodule Cart.Commands do
  defmodule AddItem do
    defstruct [:cart_id, :item_id, :quantity, :price]
  end

  defmodule RemoveItem do
    defstruct [:cart_id, :item_id]
  end

  defmodule Checkout do
    defstruct [:cart_id]
  end
end
```

### Evolve (pure function)

```elixir
defmodule Cart.State do
  defstruct items: %{}, checked_out: false

  def evolve(state, %Cart.Events.ItemAdded{item_id: id, quantity: qty, price: price}) do
    put_in(state.items[id], %{quantity: qty, price: price})
  end

  def evolve(state, %Cart.Events.ItemRemoved{item_id: id}) do
    update_in(state.items, &Map.delete(&1, id))
  end

  def evolve(state, %Cart.Events.CartCheckedOut{}) do
    %{state | checked_out: true}
  end
end
```

### Decide (effectful - uses Command + EventAccumulator)

```elixir
defmodule Cart.Handler do
  use Skuld.Syntax

  alias Cart.{Events, Commands, State}

  def handle(%Commands.AddItem{} = cmd) do
    comp do
      state <- State.get()
      _ <- if state.checked_out, do: Throw.throw(:already_checked_out)
      event = %Events.ItemAdded{
        cart_id: cmd.cart_id,
        item_id: cmd.item_id,
        quantity: cmd.quantity,
        price: cmd.price
      }
      _ <- EventAccumulator.emit(event)
      new_state = State.evolve(state, event)
      _ <- State.put(new_state)
      {:ok, new_state}
    end
  end

  def handle(%Commands.RemoveItem{} = cmd) do
    comp do
      state <- State.get()
      _ <- if state.checked_out, do: Throw.throw(:already_checked_out)
      _ <- if not Map.has_key?(state.items, cmd.item_id),
              do: Throw.throw(:item_not_found)
      event = %Events.ItemRemoved{
        cart_id: cmd.cart_id,
        item_id: cmd.item_id
      }
      _ <- EventAccumulator.emit(event)
      new_state = State.evolve(state, event)
      _ <- State.put(new_state)
      {:ok, new_state}
    end
  end

  def handle(%Commands.Checkout{cart_id: cart_id}) do
    comp do
      state <- State.get()
      _ <- if state.checked_out, do: Throw.throw(:already_checked_out)
      _ <- if map_size(state.items) == 0, do: Throw.throw(:empty_cart)
      total = state.items
              |> Map.values()
              |> Enum.reduce(0, fn %{quantity: q, price: p}, acc ->
                acc + q * p
              end)
      event = %Events.CartCheckedOut{cart_id: cart_id, total: total}
      _ <- EventAccumulator.emit(event)
      new_state = State.evolve(state, event)
      _ <- State.put(new_state)
      {:ok, %{state: new_state, total: total}}
    end
  end
end
```

### Running it

```elixir
{result, events} =
  comp do
    {:ok, _} <- Command.execute(%AddItem{
      cart_id: "c1", item_id: "widget", quantity: 2, price: 1000
    })
    {:ok, _} <- Command.execute(%AddItem{
      cart_id: "c1", item_id: "gadget", quantity: 1, price: 2500
    })
    {:ok, checkout} <- Command.execute(%Checkout{cart_id: "c1"})
    checkout
  end
  |> Command.with_handler(&Cart.Handler.handle/1)
  |> EventAccumulator.with_handler(output: fn r, evts -> {r, evts} end)
  |> State.with_handler(%Cart.State{})
  |> Throw.with_handler()
  |> Comp.run!()

# result is %{state: ..., total: 4500}
# events is [%ItemAdded{...}, %ItemAdded{...}, %CartCheckedOut{...}]
```

### Persisting events

The `output` function on EventAccumulator is where you'd publish
events to an event store, message bus, or database:

```elixir
|> EventAccumulator.with_handler(
  output: fn result, events ->
    # Persist to event store
    MyApp.EventStore.append(events)
    # Publish to subscribers
    MyApp.EventBus.publish(events)
    result
  end
)
```

## Testing

The entire decide/evolve pipeline is pure and testable without a
database:

```elixir
test "checkout calculates correct total" do
  {result, events} =
    comp do
      {:ok, _} <- Command.execute(%AddItem{
        cart_id: "c1", item_id: "a", quantity: 3, price: 100
      })
      {:ok, checkout} <- Command.execute(%Checkout{cart_id: "c1"})
      checkout
    end
    |> Command.with_handler(&Cart.Handler.handle/1)
    |> EventAccumulator.with_handler(output: fn r, e -> {r, e} end)
    |> State.with_handler(%Cart.State{})
    |> Throw.with_handler()
    |> Comp.run!()

  assert %{total: 300} = result
  assert [%ItemAdded{}, %CartCheckedOut{total: 300}] = events
end

test "cannot checkout empty cart" do
  result =
    Command.execute(%Checkout{cart_id: "c1"})
    |> Command.with_handler(&Cart.Handler.handle/1)
    |> EventAccumulator.with_handler(output: fn r, e -> {r, e} end)
    |> State.with_handler(%Cart.State{})
    |> Throw.with_handler()
    |> Comp.run()

  assert {:thrown, :empty_cart} = result
end
```

## When to use this

The Decider pattern is a good fit when:

- You need an audit trail of domain events
- Business rules depend on the history of what happened
- Multiple projections (read models) are derived from the same events
- You want to test domain logic without persistence

It's overkill for simple CRUD - use DB effects directly for that.

<!-- nav:footer:start -->

---

[< Hexagonal Architecture](hexagonal-architecture.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [Handler Stacks >](handler-stacks.md)
<!-- nav:footer:end -->
