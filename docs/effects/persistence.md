# Persistence & Data

<!-- nav:header:start -->
[< Concurrency (Familiar Patterns)](concurrency.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [External Integration >](external-integration.md)
<!-- nav:header:end -->

The Transaction and Command effects handle
transactions and mutation dispatch. They work
together to support patterns from simple CRUD through to event-sourced
domain logic.

Database persistence is handled via domain-specific
[Port.Contract](external-integration.md) modules (e.g. `UserRepo`,
`OrderRepo`), which provide typed boundaries and swappable handlers.
For common Ecto Repo operations (insert, update, delete, get, etc.),
Skuld provides a built-in [Skuld.Repo](#skuldrepo) contract so you don't
need to redeclare identical boilerplate in every domain.

Transaction is orthogonal — it wraps any computation in transactional
semantics, rolling back env state on failure with optional database
transaction support.

For read queries and external service calls, see
[External Integration](external-integration.md). For batchable queries
with automatic N+1 prevention, see
[Query & Batching](../advanced/query-batching.md).

## Skuld.Repo

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
alias Skuld.Repo

defcomp create_and_fetch(attrs) do
  changeset = User.changeset(%User{}, attrs)
  user <- Repo.insert!(changeset)
  all_users <- Repo.all(User)
  {user, all_users}
end
```

### Production handler (Skuld.Repo.Ecto)

Generate a Behaviour implementation that delegates to your Ecto Repo:

```elixir
defmodule MyApp.Repo.Ecto do
  use Skuld.Repo.Ecto, repo: MyApp.Repo
end
```

Wire it into the handler stack:

```elixir
create_and_fetch(attrs)
|> Transaction.transact()
|> Transaction.Ecto.with_handler(MyApp.Repo)
|> Port.with_handler(%{Skuld.Repo.Effectful => MyApp.Repo.Ecto})
|> Throw.with_handler()
|> Comp.run!()
```

### Test handler (Skuld.Repo.Stub)

A stateless test handler. `Repo.Stub.new/1` returns a fn resolver
that applies changeset changes for writes and delegates reads to an
optional `fallback_fn` (or raises). Register it via `Port.with_handler`
and use the `:log` option to capture a dispatch log. Each log entry is
a 4-tuple `{module, operation, args_list, return_value}`:

```elixir
alias Skuld.Effects.Port
alias Skuld.Repo

cs = User.changeset(%User{}, %{name: "Alice"})
alice = %User{id: 42, name: "Alice"}

{result, log} =
  comp do
    user <- Repo.insert!(cs)
    found <- Repo.get(User, 42)
    {user, found}
  end
  |> Port.with_handler(
    %{Skuld.Repo.Effectful => Repo.Stub.new(
      fallback_fn: fn :get, [User, 42] -> alice end
    )},
    # Note: Repo.Stub fallback is 2-arity (stateless).
    # Repo.InMemory fallback is 3-arity (receives store state).
    log: true,
    output: fn result, state -> {result, state.log} end
  )
  |> Throw.with_handler()
  |> Comp.run!()

assert {%User{name: "Alice"}, ^alice} = result
assert [
  {Repo, :insert, [^cs], {:ok, %User{name: "Alice"}}},
  {Repo, :get, [User, 42], ^alice}
] = log
```

Because logging happens at the Port level, the log captures **all**
Port dispatches — not just `Skuld.Repo` operations. Register
additional contracts in the same registry map and their dispatches
appear in the same log:

```elixir
Port.with_handler(
  comp,
  %{Skuld.Repo.Effectful => Repo.Stub.new(), MyApp.Queries => MyApp.Queries.TestImpl},
  log: true,
  output: fn r, state -> {r, state.log} end
)
```

### Combining with domain-specific contracts

Skuld.Repo handles generic persistence. Domain-specific operations
(complex queries, business logic wrapped in persistence) should still
use their own Port.Contract:

```elixir
defmodule MyApp.Orders do
  use DoubleDown.Contract

  defcallback place_order(params :: map()) ::
            {:ok, Order.t()} | {:error, term()}
end

defcomp checkout(params) do
  order <- MyApp.Orders.place_order!(params)
  audit_cs = AuditLog.changeset(%AuditLog{}, %{action: "checkout", order_id: order.id})
  _ <- Repo.insert!(audit_cs)
  order
end
```

### When to use Skuld.Repo vs a domain contract

| Situation                         | Use                  |
|-----------------------------------|----------------------|
| Generic insert/update/delete/get  | `Skuld.Repo`          |
| Domain-specific queries           | Domain Port.Contract |
| Business logic in persistence     | Domain Port.Contract |
| Audit logs, simple CRUD           | `Skuld.Repo`          |

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
  UserRepo.__key__(:create_user, params) => %User{id: "test-id", name: "Alice"}
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
Fresh for IDs, Port contracts for persistence, Writer for domain events.

### Why Command?

Command is a building block for the
[Decider pattern](https://thinkbeforecoding.com/post/2021/12/17/functional-event-sourcing-decider):
decide (interpret commands) -> evolve (apply events to state) -> persist.
Combined with Writer, you can express event-sourced domain
logic as pure effectful code. See the
[Decider Pattern recipe](../recipes/decider-pattern.md) for a full
walkthrough.

## Domain events with Writer

Writer can accumulate domain events during a computation. Use a
consistent tag (e.g. `:events`) and reverse the output since Writer
stores in reverse order:

```elixir
comp do
  _ <- Writer.tell(:events, %{type: :user_created, id: 1}) |> Comp.then_do(Comp.pure(:ok))
  _ <- Writer.tell(:events, %{type: :email_sent, to: "user@example.com"}) |> Comp.then_do(Comp.pure(:ok))
  :ok
end
|> Writer.with_handler([], tag: :events, output: fn result, events -> {result, Enum.reverse(events)} end)
|> Comp.run!()
#=> {:ok, [%{type: :user_created, id: 1}, %{type: :email_sent, to: "user@example.com"}]}
```

Writer supports more operations than simple accumulation:
`peek`, `listen`, `pass`, and `censor` for inspecting and transforming
the event log mid-computation.

### Combining with Command and Port

All three compose naturally for domain workflows:

```elixir
defmodule PlaceOrderHandler do
  use Skuld.Syntax

  def handle(%PlaceOrder{user_id: uid, items: items}) do
    comp do
      order <- OrderRepo.create_order!(%{
        user_id: uid, items: items, status: :placed
      })
      _ <- Writer.tell(:events, %OrderPlaced{
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
  |> Writer.with_handler([], tag: :events, output: fn r, evts -> {r, Enum.reverse(evts)} end)
  |> Port.with_handler(%{OrderRepo => OrderRepo.Ecto})
  |> Comp.run!()

# result is the order, events contains [%OrderPlaced{...}]
# Publish events to your event bus, persist to an event store, etc.
```

<!-- nav:footer:start -->

---

[< Concurrency (Familiar Patterns)](concurrency.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [External Integration >](external-integration.md)
<!-- nav:footer:end -->
