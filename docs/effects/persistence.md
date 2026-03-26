# Persistence & Data

<!-- nav:header:start -->
[< Concurrency (Familiar Patterns)](concurrency.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [External Integration >](external-integration.md)
<!-- nav:header:end -->

The Transaction, Command, and EventAccumulator effects handle
transactions, mutation dispatch, and domain event collection. They work
together to support patterns from simple CRUD through to event-sourced
domain logic.

Database persistence is handled via domain-specific
[Port.Contract](external-integration.md) modules (e.g. `UserRepo`,
`OrderRepo`), which provide typed boundaries and swappable handlers.
Transaction is orthogonal — it wraps any computation in transactional
semantics, rolling back env state on failure with optional database
transaction support.

For read queries and external service calls, see
[External Integration](external-integration.md). For batchable queries
with automatic N+1 prevention, see
[Query & Batching](../advanced/query-batching.md).

## Transaction

Transactional semantics for computations: on normal completion the
transaction commits (env state preserved); on explicit rollback or
sentinel (Throw, Suspend, etc.) the transaction rolls back env state to
pre-transaction values.

Transaction is orthogonal to persistence. A computation may need
transactional env state rollback without any database involvement (e.g.
rolling back Writer accumulations on error), or it may combine
transactions with domain-specific persistence Ports.

### Basic usage

```elixir
comp do
  result <- Transaction.transact(comp do
    user <- UserRepo.create_user!(params)
    order <- OrderRepo.create_order!(%{user_id: user.id, items: items})
    {user, order}
  end)
  result
end
|> Transaction.Ecto.with_handler(MyApp.Repo)
|> Port.with_handler(%{UserRepo => UserRepo.Ecto, OrderRepo => OrderRepo.Ecto})
|> Comp.run!()
```

### Operations

- `Transaction.transact(comp)` — wrap a computation in a transaction
- `Transaction.rollback(reason)` — explicitly roll back the current
  transaction

### Explicit rollback

```elixir
comp do
  result <- Transaction.transact(comp do
    _ <- Transaction.rollback(:validation_failed)
    :never_reached
  end)
  result
end
|> Transaction.Noop.with_handler()
|> Comp.run!()
#=> {:rolled_back, :validation_failed}
```

### try_transact

A convenience that wraps the outcome in `{:ok, result}` or
`{:rolled_back, reason}` for easy pattern matching:

```elixir
comp do
  case Transaction.try_transact(inner_comp) do
    {:ok, value} -> handle_success(value)
    {:rolled_back, reason} -> handle_rollback(reason)
  end
end
```

### Throws inside transactions

Throws automatically trigger rollback:

```elixir
comp do
  result <- Transaction.transact(comp do
    _ <- Throw.throw(:something_went_wrong)
    :never_reached
  end)
  result
end
|> Transaction.Ecto.with_handler(MyApp.Repo)
|> Throw.with_handler()
|> Comp.run!()
# Transaction is rolled back, throw propagates
```

### Nested transactions

Nested `transact` calls create savepoints (Ecto handler) or
independent rollback scopes (Noop handler):

```elixir
comp do
  result <- Transaction.transact(comp do
    _ <- do_outer_work()

    inner <- Transaction.transact(comp do
      _ <- do_inner_work()
      :inner_done
    end)

    {:outer_done, inner}
  end)
  result
end
```

### Handlers

**`Transaction.Ecto.with_handler(repo, opts)`** — Production handler.
Wraps the computation in `Repo.transaction/2` with env state rollback
on failure. Nested transactions use savepoints.

Options:
- `:preserve_state_on_rollback` — list of state keys to keep on
  rollback (e.g. metrics, error counters)

**`Transaction.Noop.with_handler(opts)`** — No-op handler. Env state
rollback without any database. Useful for testing code that needs
transactional semantics without a database connection.

Options:
- `:preserve_state_on_rollback` — same as Ecto handler

### Testing

For tests that don't need a real database, use the Noop handler:

```elixir
comp do
  result <- Transaction.transact(comp do
    # Port calls are stubbed via Port.with_test_handler
    user <- UserRepo.create_user!(params)
    user
  end)
  result
end
|> Transaction.Noop.with_handler()
|> Port.with_test_handler(%{
  UserRepo.key(:create_user, params) => %User{id: "test-id", name: "Alice"}
})
|> Comp.run!()
```

## Command

Dispatch mutation structs through a handler function. Command provides
a clean separation between "what mutation to perform" and "how to
perform it", routing through pattern matching.

### Basic usage

Define command structs and a handler that routes them:

```elixir
defmodule CreateTodo do
  defstruct [:title, :priority]
end

defmodule DeleteTodo do
  defstruct [:id]
end

defmodule MyCommandHandler do
  use Skuld.Syntax

  def handle(%CreateTodo{title: title, priority: priority}) do
    comp do
      id <- Fresh.fresh_uuid()
      {:ok, %{id: id, title: title, priority: priority}}
    end
  end

  def handle(%DeleteTodo{id: id}) do
    comp do
      {:ok, %{deleted: id}}
    end
  end
end
```

Execute commands through the effect system:

```elixir
comp do
  {:ok, todo} <- Command.execute(%CreateTodo{title: "Buy milk", priority: :high})
  todo
end
|> Command.with_handler(&MyCommandHandler.handle/1)
|> Fresh.with_uuid7_handler()
|> Comp.run!()
#=> %{id: "01945a3b-...", title: "Buy milk", priority: :high}
```

### Handler

```elixir
Command.with_handler(handler_fn)
```

The handler function receives a command struct and returns a
computation. This means commands can use other effects internally -
Fresh for IDs, Port contracts for persistence, EventAccumulator for domain events.

### Why Command?

Command is a building block for the
[Decider pattern](https://thinkbeforecoding.com/post/2021/12/17/functional-event-sourcing-decider):
decide (interpret commands) -> evolve (apply events to state) -> persist.
Combined with EventAccumulator, you can express event-sourced domain
logic as pure effectful code. See the
[Decider Pattern recipe](../recipes/decider-pattern.md) for a full
walkthrough.

## EventAccumulator

Accumulate domain events during a computation. Built on Writer, it
provides a focused API for collecting events that can be persisted or
published after the computation completes.

### Basic usage

```elixir
comp do
  _ <- EventAccumulator.emit(%{type: :user_created, id: 1})
  _ <- EventAccumulator.emit(%{type: :email_sent, to: "user@example.com"})
  :ok
end
|> EventAccumulator.with_handler(output: fn result, events -> {result, events} end)
|> Comp.run!()
#=> {:ok, [%{type: :user_created, id: 1}, %{type: :email_sent, to: "user@example.com"}]}
```

### Operations

- `EventAccumulator.emit(event)` - add an event to the accumulator

### Handler

```elixir
EventAccumulator.with_handler(opts)
```

Options:
- `:output` - `fn result, events -> transformed_result end` to extract
  the accumulated events alongside the computation result

### Combining with Command and Port

All three effects compose naturally for domain workflows:

```elixir
defmodule PlaceOrderHandler do
  use Skuld.Syntax

  def handle(%PlaceOrder{user_id: uid, items: items}) do
    comp do
      order <- OrderRepo.create_order!(%{
        user_id: uid, items: items, status: :placed
      })
      _ <- EventAccumulator.emit(%OrderPlaced{
        order_id: order.id, user_id: uid, items: items
      })
      {:ok, order}
    end
  end
end

{result, events} =
  comp do
    {:ok, order} <- Command.execute(%PlaceOrder{
      user_id: "u1", items: ["widget"]
    })
    order
  end
  |> Command.with_handler(&PlaceOrderHandler.handle/1)
  |> EventAccumulator.with_handler(output: fn r, evts -> {r, evts} end)
  |> Port.with_handler(%{OrderRepo => OrderRepo.Ecto})
  |> Comp.run!()

# result is the order, events contains [%OrderPlaced{...}]
# Publish events to your event bus, persist to an event store, etc.
```

<!-- nav:footer:start -->

---

[< Concurrency (Familiar Patterns)](concurrency.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [External Integration >](external-integration.md)
<!-- nav:footer:end -->
