# Query & Batching

<!-- nav:header:start -->
[< Cooperative Fibers & Concurrency](fibers-concurrency.md) | [Up: Advanced Effects](yield.md) | [Index](../../README.md) | [Serializable Coroutines (EffectLogger) >](effect-logger.md)
<!-- nav:header:end -->

Skuld's query system solves the N+1 problem with automatic batching.
You write simple per-record fetch calls; the runtime batches concurrent
calls of the same type into a single executor invocation. The `query`
macro automatically runs independent fetches concurrently.

Inspired by Facebook's [Haxl](https://github.com/facebook/Haxl).

The system has three layers:

1. **`query do` block** - compose fetches with automatic concurrency
2. **`deffetch` contracts** - typed, batchable fetch operations
3. **`Query.Cache`** - cross-batch caching and deduplication

## The N+1 problem

The N+1 problem occurs when code fetches N items and then makes a
separate query for each one. Consider a CSV import where each row needs
related lookups:

```elixir
# WITHOUT Skuld - classic N+1
def process_import(staging_rows) do
  Enum.map(staging_rows, fn row ->
    user = Repo.get_by(User, email: row.email)
    account = Repo.get_by(Account, external_id: row.account_ref)
    process_row(row, user, account)
  end)
end
```

With 1,000 rows, that's 2,000 individual queries. With Skuld:

```elixir
# WITH Skuld - per-record calls, automatic batching
defmodule Import.Queries do
  use Skuld.Query.Contract
  deffetch get_user_by_email(email :: String.t()) :: User.t() | nil
  deffetch get_account_by_ref(ref :: String.t()) :: Account.t() | nil
end

def process_row(row) do
  query do
    user <- Import.Queries.get_user_by_email(row.email)
    account <- Import.Queries.get_account_by_ref(row.account_ref)
    do_process(row, user, account)
  end
end

FiberPool.map(staging_rows, &process_row/1)
|> Import.Queries.with_executor(Import.Queries.EctoExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
# Result: 2 batched queries instead of 2,000 individual ones
```

The per-record code is unchanged. Batching happens at the runtime level
when FiberPool's scheduler collects suspended fibers and groups their
requests by type. This works even when the N+1 is buried deep in the
call stack.

### Streaming: constant-memory batching

For large imports, use [Brook](fibers-concurrency.md) for
constant-memory processing with backpressure:

```elixir
comp do
  source <- Brook.from_function(fn ->
    case StagingTable.next_batch() do
      {:ok, rows} -> {:items, rows}
      :done -> :done
    end
  end, chunk_size: 50)

  Brook.map(source, &process_row/1, concurrency: 10, buffer: 5)
  |> Brook.run(fn result -> persist_result(result) end)
end
|> Import.Queries.with_executor(Import.Queries.EctoExecutor)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

With `concurrency: 10` and `chunk_size: 50`, at most ~500 rows are in
flight at any time. Memory stays bounded, batching efficiency is the
same.

## The `query` macro

The `query` macro analyses variable dependencies at compile time and
groups independent bindings into concurrent fiber batches.

```elixir
query do
  user   <- Users.get_user(id)
  recent <- Orders.get_recent()
  orders <- Orders.get_by_user(user.id)
  {user, recent, orders}
end
```

Here `get_user` and `get_recent` are independent (neither references
the other's result), so they run concurrently. `get_by_user` depends
on `user`, so it runs in a subsequent batch.

### Syntax

- `var <- computation` - effectful binding (auto-batched if independent)
- `var = expression` - pure binding (participates in dependency analysis)
- Last expression - the block's return value (auto-lifted)

### How it works

1. Parse bindings into a dependency graph
2. Topological sort into "rounds" - a binding goes in the earliest
   round where all its dependencies are satisfied
3. Single-binding rounds use `fiber` + `await!`; multi-binding rounds
   use `fiber_all` + `await_all!`

The above compiles to roughly:

```elixir
comp do
  handles <- FiberPool.fiber_all([Users.get_user(id), Orders.get_recent()])
  [user, recent] <- FiberPool.await_all!(handles)
  handle <- FiberPool.fiber(Orders.get_by_user(user.id))
  orders <- FiberPool.await!(handle)
  {user, recent, orders}
end
```

### Differences from `comp`

- `comp` is purely sequential - each binding waits for the previous
- `query` analyses dependencies and runs independent bindings concurrently

Use `comp` for sequential effect chains. Use `query` when composing
data fetches that may be independent.

`query` requires a FiberPool handler.

## Defining fetch operations with `deffetch`

`Query.Contract` is a typed DSL for declaring batchable fetch
operations. It generates operation structs, caller functions, an
executor behaviour, and wiring helpers.

### Defining a contract

```elixir
defmodule MyApp.Queries.Users do
  use Skuld.Query.Contract

  deffetch get_user(id :: String.t()) :: User.t() | nil
  deffetch get_users_by_org(org_id :: String.t()) :: [User.t()]
  deffetch get_user_count(org_id :: String.t()) :: non_neg_integer()
end
```

Each `deffetch` generates:

- **Operation struct** - e.g. `MyApp.Queries.Users.GetUser` with typed fields
- **Caller function** - e.g. `get_user/1` returning a computation that
  suspends the current fiber for batched execution
- **Executor callback** - on `MyApp.Queries.Users.Executor`, receiving
  `[{ref, op_struct}]` and returning `computation(%{ref => result})`
- **Wiring function** - `with_executor/2` installs an executor
- **Bang variant** - when return type contains `{:ok, T}`
- **Introspection** - `__query_operations__/0`

### Implementing an executor

An executor implements one callback per fetch. Each receives a list of
`{ref, op_struct}` tuples and returns a map from refs to results:

```elixir
defmodule MyApp.Queries.Users.EctoExecutor do
  use Skuld.Syntax
  @behaviour MyApp.Queries.Users.Executor

  alias MyApp.Queries.Users.{GetUser, GetUsersByOrg}

  @impl true
  defcomp get_user(ops) do
    ids = Enum.map(ops, fn {_ref, %GetUser{id: id}} -> id end)
          |> Enum.uniq()
    results = Repo.all(from u in User, where: u.id in ^ids)
    by_id = Map.new(results, &{&1.id, &1})
    Map.new(ops, fn {ref, %GetUser{id: id}} ->
      {ref, Map.get(by_id, id)}
    end)
  end

  @impl true
  defcomp get_users_by_org(ops) do
    org_ids = Enum.map(ops, fn {_ref, %GetUsersByOrg{org_id: oid}} -> oid end)
              |> Enum.uniq()
    results = Repo.all(from u in User, where: u.org_id in ^org_ids)
    grouped = Enum.group_by(results, & &1.org_id)
    Map.new(ops, fn {ref, %GetUsersByOrg{org_id: oid}} ->
      {ref, Map.get(grouped, oid, [])}
    end)
  end

  # ... get_user_count/1
end
```

The pattern is always:
1. Extract unique parameter values from the batched ops
2. Execute a single query covering all values
3. Map results back to `%{ref => result}`

Executor callbacks return computations, so they can use any Skuld
effect (Reader, State, DB, Port, etc.).

### Wiring

Install an executor with `with_executor/2`:

```elixir
my_query
|> Users.with_executor(Users.EctoExecutor)
|> Orders.with_executor(Orders.EctoExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
```

For multiple contracts, use `Skuld.Query.Contract.with_executors/2`:

```elixir
my_query
|> Skuld.Query.Contract.with_executors([
  {MyApp.Queries.Users, MyApp.Queries.Users.EctoExecutor},
  {MyApp.Queries.Orders, MyApp.Queries.Orders.EctoExecutor}
])
|> FiberPool.with_handler()
|> Comp.run!()
```

### Bang variants

Same rules as Port.Contract:

- **Auto-detect** (default): if return type has `{:ok, T}`, bang
  generated that unwraps or throws
- **`bang: true`**: force standard unwrapping
- **`bang: false`**: suppress bang
- **`bang: unwrap_fn`**: custom unwrap function

```elixir
deffetch find_account(id :: String.t()) :: {:ok, Account.t()} | {:error, term()}
# Auto: bang generated (find_account!/1)

deffetch get_account(id :: String.t()) :: Account.t() | nil
# Auto: no bang (no {:ok, T} pattern)

deffetch lookup(id :: String.t()) :: Account.t() | nil, bang: true
# Force bang
```

## Caching

`Skuld.Query.Cache` provides cross-batch caching and within-batch
deduplication.

### Wiring with cache

Use `QueryCache.with_executor/3` instead of `Contract.with_executor/2`:

```elixir
alias Skuld.Query.Cache, as: QueryCache

my_comp
|> QueryCache.with_executor(Users, Users.EctoExecutor)
|> FiberPool.with_handler()
|> Comp.run()

# Multiple contracts with shared cache scope
my_comp
|> QueryCache.with_executors([
  {Users, Users.EctoExecutor},
  {Orders, Orders.EctoExecutor}
])
|> FiberPool.with_handler()
|> Comp.run()
```

### Cache scope and lifetime

The cache lives exactly as long as the computation run. No TTL, no
eviction - initialised empty, cleaned up on scope exit. This matches
Haxl's per-request cache semantics: within a single computation, you
get automatic deduplication with no stale data concerns.

### Cache keys

Keys are `{batch_key, op_struct}` where `batch_key` is
`{ContractModule, :query_name}` and `op_struct` is the operation
struct. Structural equality provides correct comparison - two queries
with the same parameters share a cache entry.

### Per-query opt-out

```elixir
deffetch get_random_user() :: User.t(), cache: false
```

Non-cacheable queries bypass the cache entirely.

### Error handling

Executor failures are **not cached**. The error propagates to
requesting fibers, nothing is stored, and subsequent requests retry.

## How batching works

Under the hood:

1. Each caller function creates an `InternalSuspend.batch` with a
   batch key and operation struct
2. FiberPool's scheduler collects batch-suspended fibers
3. When the run queue empties, suspensions are grouped by batch key
4. For each group, the registered executor runs with all ops
5. Results are distributed back to waiting fibers via the ref map

The programmer writes simple per-record calls. Batching is transparent.

## Testing

Implement a stub executor:

```elixir
defmodule Users.TestExecutor do
  use Skuld.Syntax
  @behaviour Users.Executor

  @impl true
  defcomp get_user(ops) do
    Map.new(ops, fn {ref, %Users.GetUser{id: id}} ->
      {ref, %User{id: id, name: "Test User #{id}"}}
    end)
  end
end
```

Or use inline anonymous executors for one-off tests:

```elixir
alias Skuld.Fiber.FiberPool.BatchExecutor

my_query
|> BatchExecutor.with_executor(
  {Users, :get_user},
  fn ops ->
    Comp.pure(Map.new(ops, fn {ref, _op} ->
      {ref, %User{id: "1", name: "Stubbed"}}
    end))
  end
)
|> FiberPool.with_handler()
|> Comp.run!()
```

## Port.Contract vs Query.Contract

| Aspect              | Port.Contract         | Query.Contract             |
|---------------------|-----------------------|----------------------------|
| Purpose             | Blocking external calls | Batchable queries          |
| Execution           | One call at a time    | Multiple calls batched     |
| Requires FiberPool  | No                    | Yes                        |
| Executor receives   | Single call args      | `[{ref, op_struct}]`       |
| Executor returns    | Single result         | `%{ref => result}`         |
| Macro               | `defport`             | `deffetch`                 |
| Handler             | `Port.with_handler/2` | `Contract.with_executor/2` |
| Composition         | `comp` (sequential)   | `query` (auto-concurrent)  |

Use Port.Contract for external calls that don't benefit from batching
(HTTP APIs, service calls). Use Query.Contract when multiple concurrent
fibers are likely to make the same type of query.

<!-- nav:footer:start -->

---

[< Cooperative Fibers & Concurrency](fibers-concurrency.md) | [Up: Advanced Effects](yield.md) | [Index](../../README.md) | [Serializable Coroutines (EffectLogger) >](effect-logger.md)
<!-- nav:footer:end -->
