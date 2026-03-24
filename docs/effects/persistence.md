# Persistence & Data

The DB, Command, and EventAccumulator effects handle database writes,
mutation dispatch, and domain event collection. They work together to
support patterns from simple CRUD through to event-sourced domain logic.

For read queries and external service calls, see
[External Integration](external-integration.md). For batchable queries
with automatic N+1 prevention, see
[Query & Batching](../advanced/query-batching.md).

## DB

Unified database writes and transactions as effects. DB wraps Ecto
operations (insert, update, upsert, delete and their bulk variants)
behind a single effect with swappable handlers: Ecto for production,
Test for stubbing, Noop for transaction-only tests.

### Basic usage

```elixir
comp do
  user <- DB.insert(User.changeset(%User{}, %{name: "Alice"}))
  order <- DB.insert(Order.changeset(%Order{}, %{user_id: user.id}))
  {user, order}
end
|> DB.Ecto.with_handler(MyApp.Repo)
|> Comp.run!()
```

### Operations

Single-record operations:

- `DB.insert(changeset)` - insert a record
- `DB.update(changeset)` - update a record
- `DB.upsert(changeset, opts)` - insert or update (pass `conflict_target:`)
- `DB.delete(struct)` - delete a record

All accept an Ecto changeset (or a `ChangeEvent` struct wrapping one).

Bulk operations:

- `DB.insert_all(schema, entries, opts)` - bulk insert
- `DB.update_all(schema, entries, opts)` - bulk update
- `DB.upsert_all(schema, entries, opts)` - bulk upsert
- `DB.delete_all(schema, entries, opts)` - bulk delete

Bulk operations return `{count, nil | [struct]}`. Pass `returning: true`
to get the inserted/updated records back.

```elixir
comp do
  {count, users} <- DB.insert_all(User, changesets, returning: true)
  {count, users}
end
|> DB.Ecto.with_handler(MyApp.Repo)
|> Comp.run!()
```

### Transactions

Wrap a computation in a transaction. Normal completion commits;
`DB.rollback/1` or a Throw inside the block triggers rollback.

```elixir
comp do
  result <- DB.transact(comp do
    user <- DB.insert(user_changeset)
    order <- DB.insert(order_changeset)
    {user, order}
  end)
  result
end
|> DB.Ecto.with_handler(MyApp.Repo)
|> Comp.run!()
```

Explicit rollback:

```elixir
comp do
  result <- DB.transact(comp do
    _ <- DB.rollback(:validation_failed)
    :never_reached
  end)
  result
end
|> DB.Noop.with_handler()
|> Comp.run!()
#=> {:rolled_back, :validation_failed}
```

Throws inside a transaction automatically trigger rollback:

```elixir
comp do
  result <- DB.transact(comp do
    _ <- Throw.throw(:something_went_wrong)
    :never_reached
  end)
  result
end
|> DB.Ecto.with_handler(MyApp.Repo)
|> Throw.with_handler()
|> Comp.run!()
# Transaction is rolled back, throw propagates
```

### Handlers

**`DB.Ecto.with_handler(repo)`** - Production handler. Dispatches to
Ecto's `Repo.insert/2`, `Repo.update/2`, etc. Transactions use
`Repo.transaction/2`.

**`DB.Noop.with_handler()`** - No-op handler. Supports transactions
(tracks commit/rollback) but raises on actual write operations. Useful
for testing code that only uses transactions without writes.

**`DB.Test.with_handler(handler_fn)`** - Test handler. Records all
operations via Writer and returns stubbed results. The handler function
receives operation structs and returns the result to use.

### Testing patterns

The test handler records operations and returns controlled results:

```elixir
{result, calls} =
  comp do
    user <- DB.insert(User.changeset(%User{}, %{name: "Alice"}))
    user
  end
  |> DB.Test.with_handler(&DB.Test.default_handler/1)
  |> Comp.run!()
#=> {%User{name: "Alice"}, [{:insert, %Ecto.Changeset{...}}]}
```

Custom handler for specific test scenarios:

```elixir
{result, calls} =
  comp do
    user <- DB.insert(changeset)
    user
  end
  |> DB.Test.with_handler(fn
    %DB.Insert{input: _cs} -> %User{id: "test-id", name: "Stubbed"}
    %DB.Update{input: cs} -> Ecto.Changeset.apply_changes(cs)
  end)
  |> Comp.run!()
#=> {%User{id: "test-id", name: "Stubbed"}, [{:insert, %Ecto.Changeset{...}}]}
```

The `calls` list lets you assert that the right operations happened in
the right order without touching a database.

### Same code, three handlers

The same domain logic works unchanged across environments:

```elixir
create_order = fn user_id, items ->
  comp do
    result <- DB.transact(comp do
      order <- DB.insert(Order.changeset(%Order{}, %{
        user_id: user_id, items: items
      }))
      order
    end)
    result
  end
end

# Production: real Ecto transactions
create_order.(123, [:item_a])
|> DB.Ecto.with_handler(MyApp.Repo)
|> Comp.run!()

# Test: no-op transactions (raises on writes)
create_order.(123, [:item_a])
|> DB.Noop.with_handler()
|> Comp.run!()

# Test: stub writes and record calls
create_order.(123, [:item_a])
|> DB.Test.with_handler(&DB.Test.default_handler/1)
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
Fresh for IDs, DB for persistence, EventAccumulator for domain events.

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

### Combining with Command and DB

The three effects compose naturally for domain workflows:

```elixir
defmodule PlaceOrderHandler do
  use Skuld.Syntax

  def handle(%PlaceOrder{user_id: uid, items: items}) do
    comp do
      order <- DB.insert(Order.changeset(%Order{}, %{
        user_id: uid, items: items, status: :placed
      }))
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
  |> DB.Ecto.with_handler(MyApp.Repo)
  |> Comp.run!()

# result is the order, events contains [%OrderPlaced{...}]
# Publish events to your event bus, persist to an event store, etc.
```
