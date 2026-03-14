# Effects: Persistence & Data

Skuld splits database interaction across several effects, each handling a distinct
concern:

- **DB** — write operations (insert, update, upsert, delete, bulk variants) and
  transaction management through a single effect with swappable handlers (Ecto for
  production, Test for stubbing and call recording, Noop for transaction-only tests).
- **Port** — abstracts read queries (and any other blocking call to external code)
  behind a dispatch layer with pluggable backends. Ecto's query language is too rich
  to wrap in an effect, so reads are parameterised function calls routed through Port,
  making them easy to stub in tests. **Port.Contract** adds typed contracts via
  `defport` declarations, generating Dialyzer-checked caller functions, behaviour
  callbacks, and test key helpers.
- **DB.Batch** — a somewhat unusual (in Elixir) solution to the N+1 query problem.
  Batch-reads suspend the current FiberPool fiber; when the run queue empties, the
  scheduler groups pending reads by schema and executes a single batched query per
  group, distributing results back to the waiting fibers. The programmer writes
  simple per-record fetch calls and gets automatic batching for free.
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

## DB.Batch

Batched database reads using FiberPool. Multiple concurrent fetch operations for the
same schema are automatically batched into a single query, solving the N+1 problem:

```elixir
use Skuld.Syntax
alias Skuld.Effects.{DB, FiberPool}

comp do
  h1 <- FiberPool.fiber(DB.Batch.fetch(User, 1))
  h2 <- FiberPool.fiber(DB.Batch.fetch(User, 2))
  h3 <- FiberPool.fiber(DB.Batch.fetch(User, 3))

  FiberPool.await_all([h1, h2, h3])
end
|> DB.Batch.with_executors()
|> Reader.with_handler(MyApp.Repo, tag: :repo)
|> FiberPool.with_handler()
|> FiberPool.run!()
# All 3 fetches batched into a single WHERE id IN (...) query
```

Operations: `fetch/2` (single record by ID), `fetch_all/3` (records matching a filter)

See the [Concurrency effects - Brook I/O Batching](effects-concurrency.md#io-batching-in-brook)
section for a full example of automatic batching with nested reads across concurrent fibers.

## Port

Dispatch parameterizable blocking calls to pluggable backends. Ideal for wrapping
any existing side-effecting code (database queries, HTTP calls, file I/O, etc.).
Port uses positional arguments — the third argument to `Port.request/3` is a list
of args, and dispatch uses `apply(module, name, args)`:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Port, Throw}

# Define a module with side-effecting functions (positional args)
defmodule MyQueries do
  def find_user(id), do: {:ok, %{id: id, name: "User #{id}"}}
end

# Runtime: dispatch to actual modules
comp do
  user <- Port.request!(MyQueries, :find_user, [123])
  user
end
|> Port.with_handler(%{MyQueries => :direct})
|> Throw.with_handler()
|> Comp.run!()
#=> %{id: 123, name: "User 123"}

# Test: exact key matching with stub responses
comp do
  user <- Port.request!(MyQueries, :find_user, [456])
  user
end
|> Port.with_test_handler(%{
  Port.key(MyQueries, :find_user, [456]) => {:ok, %{id: 456, name: "Stubbed"}}
})
|> Throw.with_handler()
|> Comp.run!()
#=> %{id: 456, name: "Stubbed"}

# Test: function-based handler with pattern matching (ideal for property tests)
comp do
  user <- Port.request!(MyQueries, :find_user, [789])
  user
end
|> Port.with_fn_handler(fn
  MyQueries, :find_user, [id] -> {:ok, %{id: id, name: "Generated User #{id}"}}
  MyQueries, :list_users, [limit] when limit > 100 -> {:error, :limit_too_high}
  _mod, _fun, _args -> {:ok, :default}
end)
|> Throw.with_handler()
|> Comp.run!()
#=> %{id: 789, name: "Generated User 789"}
```

The function handler enables Elixir's full pattern matching power — pins, guards,
wildcards — making it ideal for property-based tests where exact values aren't
known upfront. Use `with_test_handler` for simple exact-match cases and
`with_fn_handler` for complex dynamic scenarios.

**Resolver types:**

- `:direct` — `apply(mod, name, args)` (call directly on the registered module)
- `module` — `apply(module, name, args)` (implementation module, for contract->impl dispatch)
- `fun/3` — `fun.(mod, name, args)` (function receives all three)
- `{module, function}` — `apply(module, function, [mod, name, args])`

## Port.Contract

For typed, Dialyzer-checked port operations, use `Port.Contract`. It generates caller
functions, behaviour callbacks, test key helpers, and introspection from `defport`
declarations. Bang variants are generated automatically when the return type follows
the `{:ok, T} | {:error, reason}` convention:

```elixir
defmodule MyApp.Repository do
  use Skuld.Effects.Port.Contract

  alias MyApp.Todo

  # Bang auto-generated: return type has {:ok, T}
  defport get_todo(tenant_id :: String.t(), id :: String.t()) ::
            {:ok, Todo.t()} | {:error, term()}

  defport list_todos(tenant_id :: String.t(), opts :: map()) ::
            {:ok, [Todo.t()]} | {:error, term()}

  # No bang auto-generated: return type is bare (no {:ok, T})
  defport health_check() :: :ok | {:error, term()}
end
```

This generates for each `defport`:

- **Caller** — `get_todo(tenant_id, id)` returning `computation({:ok, Todo.t()} | {:error, term()})`
- **Bang** (when applicable) — `get_todo!(tenant_id, id)` returning `computation(Todo.t())` (unwraps `{:ok, v}` or throws)
- **Callback** — `@callback get_todo(String.t(), String.t()) :: {:ok, Todo.t()} | {:error, term()}`
- **Key helper** — `key(:get_todo, tenant_id, id)` for test stub matching
- **Introspection** — `__port_operations__/0`

**Bang variant generation** is controlled by auto-detection with optional overrides
via the `bang:` option:

```elixir
defmodule MyApp.Users do
  use Skuld.Effects.Port.Contract

  # Auto-detect (default): bang generated because return type has {:ok, T}
  defport get_user(id :: String.t()) ::
            {:ok, User.t()} | {:error, term()}

  # Auto-detect: NO bang generated because return type has no {:ok, T}
  defport find_user(id :: String.t()) :: User.t() | nil

  # bang: true — force standard {:ok, v}/{:error, r} unwrapping even
  # when the return type doesn't match the pattern
  defport find_by_email(email :: String.t()) :: User.t() | nil, bang: true

  # bang: false — suppress bang even though return type has {:ok, T}
  defport raw_query(sql :: String.t()) ::
            {:ok, term()} | {:error, term()},
            bang: false

  # bang: custom_fn — generate bang using a custom unwrap function.
  # The function receives the raw implementation result and must
  # return {:ok, value} or {:error, reason}
  defport find_user_safe(id :: String.t()) :: User.t() | nil,
    bang: fn
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
end
```

This makes Contract easy to fit to **existing implementation code** regardless of
its return convention — implementations that return bare values, nillable results,
or custom result types can all have bang variants with appropriate unwrapping.

### Implementation modules

Implementation modules add `@behaviour` and `@impl`:

```elixir
defmodule MyApp.Repository.Ecto do
  @behaviour MyApp.Repository

  @impl true
  def get_todo(tenant_id, id) do
    case Repo.get_by(Todo, tenant_id: tenant_id, id: id) do
      nil -> {:error, {:not_found, Todo, id}}
      todo -> {:ok, todo}
    end
  end

  @impl true
  def list_todos(tenant_id, opts), do: ...

  @impl true
  def health_check, do: :ok
end
```

### Handler installation

```elixir
# Production: dispatch to Ecto implementation
my_comp
|> Port.with_handler(%{MyApp.Repository => MyApp.Repository.Ecto})
|> Comp.run!()

# Test: dispatch to in-memory implementation
my_comp
|> Port.with_handler(%{MyApp.Repository => MyApp.Repository.InMemory})
|> Comp.run!()

# Test: stub with generated key helpers
my_comp
|> Port.with_test_handler(%{
  MyApp.Repository.key(:get_todo, "tenant-1", "id-1") => {:ok, mock_todo}
})
|> Throw.with_handler()
|> Comp.run!()
```

**Benefits over raw `Port.request`:**

- Dialyzer checks call sites and implementations via `@spec` and `@callback`
- LSP autocomplete on `Repository.` shows available operations
- Missing callback implementations produce compiler warnings
- `key/N` helpers replace verbose `Port.key(Module, :name, [args...])` calls
- Bang generation adapts to any return convention via `bang:` option

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
