# Effects: Persistence & Data

Skuld splits database interaction across several effects, each handling a distinct
concern:

- **DB** — write operations (insert, update, upsert, delete, bulk variants) and
  transaction management through a single effect with swappable handlers (Ecto for
  production, Test for stubbing and call recording, Noop for transaction-only tests).
- **[Port](effects-port.md)** — abstracts read queries (and any other blocking call
  to external code) behind a dispatch layer with pluggable backends. Ecto's query
  language is too rich to wrap in an effect, so reads are parameterised function calls
  routed through Port, making them easy to stub in tests. **Port.Contract** adds typed
  contracts via `defport`, and **Port.Provider** enables the reverse direction — plain
  code calling into effectful implementations.
- **Query.Contract** — a typed DSL for batchable queries, solving the N+1 problem.
  `deffetch` declarations generate operation structs, typed caller functions, an
  Executor behaviour, and wiring helpers. Batch-reads suspend the current FiberPool
  fiber; when the run queue empties, the scheduler groups pending reads by query type
  and executes a single batched query per group, distributing results back to the
  waiting fibers. The programmer writes simple per-record fetch calls and gets
  automatic batching for free, with full type safety and LSP completion.
- **Command** and **EventAccumulator** — building blocks for the
  [Decider pattern](https://thinkbeforecoding.com/post/2021/12/17/functional-event-sourcing-decider).
  Command dispatches mutation structs through a handler that returns a computation;
  EventAccumulator accumulates domain events via Writer. Together they let you
  express decide -> evolve -> persist pipelines as pure effectful code.

## DB

Unified database writes and transactions as effects (requires Ecto). The `DB` effect
provides single operations (insert, update, upsert, delete), bulk operations
(insert_all, update_all, upsert_all, delete_all), and transaction management through
a single effect signature with swappable handlers.

### Single write operations

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.DB

# Production: real Ecto operations
comp do
  user <- DB.insert(User.changeset(%User{}, %{name: "Alice"}))
  order <- DB.insert(Order.changeset(%Order{}, %{user_id: user.id}))
  {user, order}
end
|> DB.Ecto.with_handler(MyApp.Repo)
|> Comp.run!()
```

Operations accept changesets or `ChangeEvent` structs:

```elixir
use Skuld.Syntax
alias Skuld.Effects.{DB, ChangeEvent}

comp do
  user <- DB.insert(changeset)                         # from changeset
  user <- DB.insert(ChangeEvent.insert(changeset))     # from ChangeEvent
  user <- DB.update(User.changeset(user, %{name: "Bob"}))
  user <- DB.upsert(changeset, conflict_target: :email)
  {:ok, _} <- DB.delete(user)
  user
end
```

### Bulk operations

```elixir
use Skuld.Syntax
alias Skuld.Effects.DB

comp do
  {count, users} <- DB.insert_all(User, changesets, returning: true)
  {count, nil}   <- DB.update_all(User, changesets)
  {count, nil}   <- DB.delete_all(User, structs)
  {count, users}
end
|> DB.Ecto.with_handler(MyApp.Repo)
|> Comp.run!()
```

### Transactions with automatic commit/rollback

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.DB

# Normal completion - transaction commits
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

# Explicit rollback
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
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{DB, Throw}

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

The same domain code works with different handlers:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.DB

create_order = fn user_id, items ->
  comp do
    result <- DB.transact(comp do
      order = %{id: 1, user_id: user_id, items: items}
      order
    end)
    result
  end
end

# Production: real Ecto transactions
create_order.(123, [:item_a, :item_b])
|> DB.Ecto.with_handler(MyApp.Repo)
|> Comp.run!()

# Testing: no-op transactions (raises on writes)
create_order.(123, [:item_a, :item_b])
|> DB.Noop.with_handler()
|> Comp.run!()

# Testing: stub writes and record calls
{result, calls} =
  comp do
    user <- DB.insert(User.changeset(%User{}, %{name: "Alice"}))
    user
  end
  |> DB.Test.with_handler(&DB.Test.default_handler/1)
  |> Comp.run!()
#=> {%User{name: "Alice"}, [{:insert, %Ecto.Changeset{...}}]}
```

The test handler records all operations via Writer and returns stubbed results:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.DB

# Custom handler for specific test scenarios
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

## Query.Contract

Typed batchable queries using FiberPool. `deffetch` declarations generate operation
structs, typed caller functions, an Executor behaviour, dispatch, and wiring helpers.
Multiple concurrent query calls are automatically batched, solving the N+1 problem:

```elixir
defmodule MyApp.Queries.Users do
  use Skuld.Query.Contract

  deffetch get_user(id :: String.t()) :: User.t() | nil
  deffetch get_users_by_org(org_id :: String.t()) :: [User.t()]
end
```

The programmer writes simple per-record query calls. When multiple fibers make the
same type of query concurrently, they are automatically batched into a single executor
invocation:

```elixir
FiberPool.map(["1", "2", "3"], &MyApp.Queries.Users.get_user/1)
|> MyApp.Queries.Users.with_executor(MyApp.Queries.Users.EctoExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
# All 3 get_user calls batched into a single executor invocation
```

Queries can be wrapped with `Skuld.Query.Cache` for automatic cross-batch result
caching and within-batch request deduplication:

```elixir
alias Skuld.Query.Cache, as: QueryCache

FiberPool.map(["1", "2", "3"], &MyApp.Queries.Users.get_user/1)
|> QueryCache.with_executor(MyApp.Queries.Users, MyApp.Queries.Users.EctoExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
```

See **[Query documentation](query.md)** for the full API:
the `query` macro, `deffetch` contract definition, executor implementation,
wiring, bulk wiring, caching, bang variants, introspection, and testing patterns.

See also [Concurrency effects - Brook I/O Batching](effects-concurrency.md#io-batching-in-brook)
for automatic batching with nested reads across concurrent fibers.

## Port

Port abstracts read queries and other blocking calls behind a dispatch layer with
pluggable backends, making them easy to stub in tests. Port.Contract adds typed
contracts via `defport` declarations with Consumer/Provider behaviour generation,
and Port.Provider enables the reverse direction — plain code calling into effectful
implementations.

See **[Port documentation](effects-port.md)** for the full API: low-level
`Port.request`, typed `Port.Contract`, provider-side `Port.Provider`, handler
types, and testing patterns.

## Command

Dispatch commands (mutations) through a unified handler:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Command, Fresh}

# Define command structs
defmodule CreateTodo do
  defstruct [:title, :priority]
end

defmodule DeleteTodo do
  defstruct [:id]
end

# Define a command handler that routes via pattern matching
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

# Execute commands through the effect system
comp do
  {:ok, todo} <- Command.execute(%CreateTodo{title: "Buy milk", priority: :high})
  todo
end
|> Command.with_handler(&MyCommandHandler.handle/1)
|> Fresh.with_uuid7_handler()
|> Comp.run!()
#=> %{id: "01945a3b-...", title: "Buy milk", priority: :high}
```

The handler function returns a computation, so commands can use other effects
(Fresh, DB, EventAccumulator, etc.) internally. This enables a clean
separation between command dispatch and command implementation.

## EventAccumulator

Accumulate domain events during computation (built on Writer):

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.EventAccumulator

comp do
  _ <- EventAccumulator.emit(%{type: :user_created, id: 1})
  _ <- EventAccumulator.emit(%{type: :email_sent, to: "user@example.com"})
  :ok
end
|> EventAccumulator.with_handler(output: fn result, events -> {result, events} end)
|> Comp.run!()
#=> {:ok, [%{type: :user_created, id: 1}, %{type: :email_sent, to: "user@example.com"}]}
```
