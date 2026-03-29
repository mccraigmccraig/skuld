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
For common Ecto Repo operations (insert, update, delete, get, etc.),
Skuld provides a built-in [Port.Repo](#portrepo) contract so you don't
need to redeclare identical boilerplate in every domain.

Transaction is orthogonal — it wraps any computation in transactional
semantics, rolling back env state on failure with optional database
transaction support.

For read queries and external service calls, see
[External Integration](external-integration.md). For batchable queries
with automatic N+1 prevention, see
[Query & Batching](../advanced/query-batching.md).

## Port.Repo

A built-in Port contract providing standard Ecto Repo operations. Use
it when your effectful code needs generic persistence (insert, update,
delete, get, all, etc.) without defining a domain-specific contract for
each operation.

### Operations

**Writes** — return `{:ok, struct()} | {:error, Ecto.Changeset.t()}`
with auto-generated bang variants:

- `insert(changeset)` / `insert!(changeset)`
- `update(changeset)` / `update!(changeset)`
- `delete(record)` / `delete!(record)`

**Bulk** — return `{count, nil | list}`:

- `update_all(queryable, updates, opts)`
- `delete_all(queryable, opts)`

**Reads** — follow Ecto's conventions:

- `get(queryable, id)` / `get!(queryable, id)`
- `get_by(queryable, clauses)` / `get_by!(queryable, clauses)`
- `one(queryable)` / `one!(queryable)`
- `all(queryable)`
- `exists?(queryable)`
- `aggregate(queryable, aggregate, field)`

### Usage in computations

```elixir
alias Skuld.Effects.Port.Repo

defcomp create_and_fetch(attrs) do
  changeset = User.changeset(%User{}, attrs)
  user <- Repo.EffectPort.insert!(changeset)
  all_users <- Repo.EffectPort.all(User)
  {user, all_users}
end
```

### Production handler (Port.Repo.Ecto)

Generate a Behaviour implementation that delegates to your Ecto Repo:

```elixir
defmodule MyApp.Repo.Port do
  use Skuld.Effects.Port.Repo.Ecto, repo: MyApp.Repo
end
```

Wire it into the handler stack:

```elixir
create_and_fetch(attrs)
|> Transaction.transact()
|> Transaction.Ecto.with_handler(MyApp.Repo)
|> Port.with_handler(%{Port.Repo => MyApp.Repo.Port})
|> Throw.with_handler()
|> Comp.run!()
```

### Test handler (Port.Repo.Test)

An effectful test executor that applies changeset changes (without
touching a database) and returns sensible defaults for reads. Register
it as an effectful resolver via `Port.with_handler` and use the `:log`
option to capture a dispatch log. Each log entry is a 4-tuple
`{module, operation, args_list, return_value}`:

```elixir
alias Skuld.Effects.Port
alias Skuld.Effects.Port.Repo

cs = User.changeset(%User{}, %{name: "Alice"})

{result, log} =
  comp do
    user <- Repo.EffectPort.insert!(cs)
    _ <- Repo.EffectPort.get(User, 42)
    user
  end
  |> Port.with_handler(
    %{Repo => Repo.Test},
    log: true,
    output: fn result, state -> {result, state.log} end
  )
  |> Throw.with_handler()
  |> Comp.run!()

assert %User{name: "Alice"} = result
assert [
  {Repo, :insert, [^cs], {:ok, %User{name: "Alice"}}},
  {Repo, :get, [User, 42], nil}
] = log
```

Because logging happens at the Port level, the log captures **all**
Port dispatches — not just `Port.Repo` operations. Register
additional contracts in the same registry map and their dispatches
appear in the same log:

```elixir
Port.with_handler(
  comp,
  %{Repo => Repo.Test, MyApp.Queries => MyApp.Queries.TestImpl},
  log: true,
  output: fn r, state -> {r, state.log} end
)
```

### Combining with domain-specific contracts

Port.Repo handles generic persistence. Domain-specific operations
(complex queries, business logic wrapped in persistence) should still
use their own Port.Contract:

```elixir
defmodule MyApp.Orders do
  use Skuld.Effects.Port.Contract

  defport place_order(params :: map()) ::
            {:ok, Order.t()} | {:error, term()}
end

defcomp checkout(params) do
  order <- MyApp.Orders.EffectPort.place_order!(params)
  audit_cs = AuditLog.changeset(%AuditLog{}, %{action: "checkout", order_id: order.id})
  _ <- Repo.EffectPort.insert!(audit_cs)
  order
end
```

### When to use Port.Repo vs a domain contract

| Situation                         | Use                  |
|-----------------------------------|----------------------|
| Generic insert/update/delete/get  | `Port.Repo`          |
| Domain-specific queries           | Domain Port.Contract |
| Business logic in persistence     | Domain Port.Contract |
| Audit logs, simple CRUD           | `Port.Repo`          |

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
    user <- UserRepo.EffectPort.create_user!(params)
    order <- OrderRepo.EffectPort.create_order!(%{user_id: user.id, items: items})
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
    user <- UserRepo.EffectPort.create_user!(params)
    user
  end)
  result
end
|> Transaction.Noop.with_handler()
|> Port.with_test_handler(%{
  UserRepo.EffectPort.key(:create_user, params) => %User{id: "test-id", name: "Alice"}
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
      order <- OrderRepo.EffectPort.create_order!(%{
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
