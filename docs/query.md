# Query

Heavily inspired by [Haxl](https://github.com/facebook/Haxl).

Skuld's query system solves the N+1 problem with automatic batching and
concurrency. You write simple per-record fetch calls; the runtime batches
concurrent calls of the same type into a single executor invocation, and the
`query` macro automatically runs independent fetches concurrently.

The system has three layers:

1. **`query do` block** — compose fetch operations with automatic concurrency
2. **`deffetch` contracts** — declare typed, batchable fetch operations
3. **`Query.Cache`** — cross-batch caching and within-batch deduplication

## The N+1 Problem

The N+1 problem occurs when code fetches a collection of N items and then makes
a separate query for each one — 1 query for the list, then N queries for
related data. This happens naturally whenever per-record fetch logic is spread
across helper functions, and the caller iterates a collection.

### Example: CSV Import Processing

Consider importing rows from a staging table, where processing each row needs
to look up related records:

```elixir
# WITHOUT Skuld — classic N+1
def process_import(staging_rows) do
  Enum.map(staging_rows, fn row ->
    # Each call hits the DB individually — N queries for users, N for accounts
    user = Repo.get_by(User, email: row.email)
    account = Repo.get_by(Account, external_id: row.account_ref)
    process_row(row, user, account)
  end)
end
```

With 1,000 staging rows, this makes 2,000 individual queries. With Skuld's
query system, you write the same per-record logic, but the runtime batches
automatically:

```elixir
# WITH Skuld — per-record calls, automatic batching
defmodule Import.Queries do
  use Skuld.Query.Contract

  deffetch get_user_by_email(email :: String.t()) :: User.t() | nil
  deffetch get_account_by_ref(ref :: String.t()) :: Account.t() | nil
end

# Processing a single row — reads like normal per-record code
defcomp process_row(row) do
  user <- Import.Queries.get_user_by_email(row.email)
  account <- Import.Queries.get_account_by_ref(row.account_ref)
  do_process(row, user, account)
end

# Process all rows — FiberPool.map spawns concurrent fibers,
# and all get_user_by_email calls batch into one executor invocation,
# all get_account_by_ref calls batch into another
FiberPool.map(staging_rows, &process_row/1)
|> Import.Queries.with_executor(Import.Queries.EctoExecutor)
|> FiberPool.with_handler()
|> FiberPool.run!()
# Result: 2 batched queries instead of 2,000 individual ones
```

The per-record code is simple and composable — `process_row` doesn't know or
care that it runs concurrently alongside hundreds of other rows. The batching
happens at the runtime level when the FiberPool scheduler collects suspended
fibers and groups their batch requests by type.

This works even when the N+1 is buried deep in the call stack — a helper
function three levels down that calls `get_user_by_email` still participates in
the same batch, because batching is a property of the runtime, not the call
site.

### Streaming: Constant-Memory Batching

The `FiberPool.map` example above loads all staging rows into memory at once.
For large imports — millions of rows, or an unbounded stream of incoming
data — you can use [Brook](effects-concurrency.md#brook) (Skuld's streaming
API) for **constant-memory** batched processing. Brook uses bounded channel
buffers for backpressure: only a fixed window of items is in flight at any
time, while batching still works across all concurrent fibers in that window.

```elixir
# Constant-memory streaming import — batching + backpressure
comp do
  # Stream rows from the staging table (or any source)
  source <- Brook.from_function(fn ->
    case StagingTable.next_batch() do
      {:ok, rows} -> {:items, rows}
      :done -> :done
    end
  end, chunk_size: 50)

  # Process rows with bounded concurrency — buffer size controls
  # how many chunks are in flight (and thus how many fibers batch together)
  Brook.map(source, &process_row/1, concurrency: 10, buffer: 5)
  |> Brook.run(fn result -> persist_result(result) end)
end
|> Import.Queries.with_executor(Import.Queries.EctoExecutor)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> FiberPool.run!()
```

With `concurrency: 10` and `chunk_size: 50`, at most ~500 rows are being
processed at any time. The `deffetch` calls from those ~500 rows batch into
just a handful of executor invocations per round, regardless of whether the
total import is 1,000 rows or 10 million. Memory stays bounded, and the
batching efficiency is the same as the in-memory version.

See the [Brook documentation](effects-concurrency.md#brook) for the full
streaming API, including `from_enum`, `from_function`, `map`, `filter`, `each`,
and backpressure configuration.

### Example: GraphQL Resolvers

GraphQL is the canonical N+1 scenario. A query like `{ posts { author { name } } }`
resolves each post's `author` field individually — if there are 50 posts, that's
50 author lookups:

```elixir
# WITHOUT batching — N+1 in every list-of-objects resolver
object :post do
  field :author, :user do
    resolve fn post, _, _ ->
      {:ok, Repo.get(User, post.author_id)}  # called once per post
    end
  end
end
```

With Skuld's query system, per-field resolvers stay simple while batching happens
automatically across all concurrent fibers in a resolution round:

```elixir
# Skuld query contracts for the data layer
defmodule Blog.Queries do
  use Skuld.Query.Contract

  deffetch get_user(id :: String.t()) :: User.t() | nil
  deffetch get_comments(post_id :: String.t()) :: [Comment.t()]
end

# Per-field resolver logic — still per-record, but batches automatically
defcomp resolve_author(post) do
  author <- Blog.Queries.get_user(post.author_id)
  author
end
```

When 50 posts resolve their `author` field concurrently, all 50
`get_user` calls are batched into a single executor invocation that
receives all 50 author IDs at once.

> **Note:** Integrating Skuld with Absinthe's resolution pipeline would require
> an Absinthe plugin (similar to how `Absinthe.Middleware.Dataloader` works).
> Absinthe's plugin system supports suspension-based batching — resolvers
> suspend during resolution, the plugin executes batches between passes, and
> Absinthe re-runs resolution to deliver results. See the
> [Absinthe integration](#absinthe-integration) section for details.

## The `query` Macro

The `query` macro (`Skuld.Query.QueryBlock`) provides the lowest-boilerplate way to
compose batchable fetch computations. It analyses variable dependencies at compile
time and automatically groups independent bindings into concurrent fiber batches.

```elixir
use Skuld.Syntax

query do
  user   <- Users.get_user(id)
  recent <- Orders.get_recent()
  orders <- Orders.get_by_user(user.id)
  {user, recent, orders}
end
```

The right-hand side of each `<-` binding can be **any Skuld computation** — a
`Comp.pure(...)`, a `comp do ... end` block, a `State.get()`, or any other
effectful expression. However, the caller functions generated by `deffetch`
contracts (described below) are specifically designed to work with the query
batching system: when multiple fibers make the same type of `deffetch` call
concurrently, the runtime automatically batches them into a single executor
invocation. The `deffetch` contracts also provide compile-time benefits — typed
`@spec`s for LSP support, generated `@callback`s for executor implementations,
and compiler checks on the executor behaviour.

Here `get_user` and `get_recent` are independent (neither references the other's
result), so they run concurrently in the same fiber batch. `get_by_user` depends on
`user`, so it runs in a subsequent batch after the first completes.

### Syntax

- `var <- computation` — effectful binding (auto-batched if independent)
- `var = expression` — pure binding (participates in dependency analysis)
- Last expression — the block's return value (auto-lifted to `Comp.pure`)

### How It Works

The macro performs compile-time dependency analysis:

1. Parse the block into `<-` / `=` bindings plus a final expression
2. For each binding, compute which bound variables from earlier bindings are
   referenced in its right-hand side
3. Group bindings into "rounds" using topological sort — a binding goes in the
   earliest round where all its dependencies are satisfied
4. Single-binding rounds use `FiberPool.fiber` + `await!`; multi-binding rounds
   use `FiberPool.fiber_all` + `await_all!`

The above example compiles to roughly:

```elixir
FiberPool.fiber_all([Users.get_user(id), Orders.get_recent()])
|> Comp.bind(&FiberPool.await_all!/1)
|> Comp.bind(fn [user, recent] ->
  FiberPool.fiber(Orders.get_by_user(user.id))
  |> Comp.bind(&FiberPool.await!/1)
  |> Comp.bind(fn orders ->
    Comp.pure({user, recent, orders})
  end)
end)
```

Or equivalently, using `comp` with the fiber boilerplate explicit:

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

Both `comp` and `query` use do-block syntax with `<-` bindings, but:

- **`comp`** is purely sequential — each binding waits for the previous one
- **`query`** analyses dependencies and runs independent bindings concurrently

Use `comp` for sequential effect chains (state updates, error handling). Use
`query` when composing data fetches that may be independent.

### Requirements

`query` requires a `FiberPool` handler to be installed, since it spawns fibers
for concurrency.

## Defining Fetch Operations with `deffetch`

`Query.Contract` (`Skuld.Query.Contract`) is a typed DSL for declaring batchable
fetch operations. It generates the operation structs, caller functions, executor
behaviour, and wiring that the `query` macro (and `FiberPool`) use for batching.

### Defining a Contract

```elixir
defmodule MyApp.Queries.Users do
  use Skuld.Query.Contract

  deffetch get_user(id :: String.t()) :: User.t() | nil
  deffetch get_users_by_org(org_id :: String.t()) :: [User.t()]
  deffetch get_user_count(org_id :: String.t()) :: non_neg_integer()
end
```

Each `deffetch` declaration generates:

- **Operation struct** — e.g. `MyApp.Queries.Users.GetUser` with typed fields
- **Caller function** — e.g. `get_user/1` returning `computation(User.t() | nil)`,
  which suspends the current fiber for batched execution
- **Executor callback** — on `MyApp.Queries.Users.Executor`, receiving a list of
  `{ref, op_struct}` tuples and returning `computation(%{ref => result})`
- **Dispatch function** — `__dispatch__/3` routes from batch key to executor callback
- **Wiring function** — `with_executor/2` installs an executor for all fetches
- **Bang variant** — when the return type contains `{:ok, T}` (see below)
- **Introspection** — `__query_operations__/0` returns metadata

### Implementing an Executor

An executor implements the generated behaviour with one callback per fetch:

```elixir
defmodule MyApp.Queries.Users.EctoExecutor do
  use Skuld.Syntax

  @behaviour MyApp.Queries.Users.Executor

  alias Skuld.Effects.Reader
  alias MyApp.Queries.Users.{GetUser, GetUsersByOrg, GetUserCount}

  @impl true
  defcomp get_user(ops) do
    ids = Enum.map(ops, fn {_ref, %GetUser{id: id}} -> id end) |> Enum.uniq()
    repo <- Reader.ask(:repo)

    results = repo.all(from u in User, where: u.id in ^ids)
    by_id = Map.new(results, &{&1.id, &1})

    Map.new(ops, fn {ref, %GetUser{id: id}} ->
      {ref, Map.get(by_id, id)}
    end)
  end

  @impl true
  defcomp get_users_by_org(ops) do
    org_ids = Enum.map(ops, fn {_ref, %GetUsersByOrg{org_id: oid}} -> oid end) |> Enum.uniq()
    repo <- Reader.ask(:repo)

    results = repo.all(from u in User, where: u.org_id in ^org_ids)
    grouped = Enum.group_by(results, & &1.org_id)

    Map.new(ops, fn {ref, %GetUsersByOrg{org_id: oid}} ->
      {ref, Map.get(grouped, oid, [])}
    end)
  end

  @impl true
  defcomp get_user_count(ops) do
    org_ids = Enum.map(ops, fn {_ref, %GetUserCount{org_id: oid}} -> oid end) |> Enum.uniq()
    repo <- Reader.ask(:repo)

    counts =
      repo.all(from u in User, where: u.org_id in ^org_ids,
        group_by: u.org_id, select: {u.org_id, count(u.id)})
      |> Map.new()

    Map.new(ops, fn {ref, %GetUserCount{org_id: oid}} ->
      {ref, Map.get(counts, oid, 0)}
    end)
  end
end
```

The pattern is always:
1. Extract unique parameter values from the batched ops
2. Execute a single query covering all values
3. Map results back to `%{request_id => result}`

Since executor callbacks return computations, they can use any Skuld effect
(Reader, State, DB, Port, etc.).

### Wiring

Install an executor for a contract using `with_executor/2`:

```elixir
query do
  user   <- Users.get_user("1")
  recent <- Orders.get_recent()
  {user, recent}
end
|> Users.with_executor(Users.EctoExecutor)
|> Orders.with_executor(Orders.EctoExecutor)
|> FiberPool.with_handler()
|> FiberPool.run!()
```

`with_executor/2` registers the executor for *all* fetches in the contract. Each
fetch type batches independently — `get_user` calls batch together,
`get_users_by_org` calls batch together, but they don't mix.

### Bulk Wiring

For applications with multiple contracts, use `Skuld.Query.Contract.with_executors/2`:

```elixir
my_query_comp
|> Skuld.Query.Contract.with_executors([
  {MyApp.Queries.Users, MyApp.Queries.Users.EctoExecutor},
  {MyApp.Queries.Orders, MyApp.Queries.Orders.EctoExecutor}
])
```

Also accepts a map:

```elixir
my_query_comp
|> Skuld.Query.Contract.with_executors(%{
  MyApp.Queries.Users => MyApp.Queries.Users.EctoExecutor,
  MyApp.Queries.Orders => MyApp.Queries.Orders.EctoExecutor
})
```

### Bang Variants

Same rules as `Port.Contract`:

- **Auto-detect** (default): If the return type contains `{:ok, T}`, a bang
  variant is generated that unwraps `{:ok, value}` or dispatches `Throw` on
  `{:error, reason}`.
- **`bang: true`**: Force standard unwrapping.
- **`bang: false`**: Suppress bang generation.
- **`bang: unwrap_fn`**: Custom unwrap function.

```elixir
defmodule MyApp.Queries.Accounts do
  use Skuld.Query.Contract

  # Auto-detect: {:ok, T} in return type -> bang generated
  deffetch find_account(id :: String.t()) :: {:ok, Account.t()} | {:error, term()}

  # No {:ok, T} pattern -> no bang
  deffetch get_account(id :: String.t()) :: Account.t() | nil

  # Force bang
  deffetch lookup_account(id :: String.t()) :: Account.t() | nil, bang: true

  # Suppress bang
  deffetch search_accounts(q :: String.t()) :: {:ok, [Account.t()]} | {:error, term()},
    bang: false

  # Custom unwrap
  deffetch fetch_account(id :: String.t()) :: map(),
    bang: fn result -> {:ok, result} end
end
```

### Introspection

Every contract module provides `__query_operations__/0`:

```elixir
MyApp.Queries.Users.__query_operations__()
#=> [
#     %{name: :get_user, params: [:id], param_types: [...], return_type: ..., arity: 1, cacheable: true},
#     %{name: :get_users_by_org, params: [:org_id], ..., cacheable: true},
#     %{name: :get_user_count, params: [:org_id], ..., cacheable: true}
#   ]
```

## Caching

`Skuld.Query.Cache` provides a composable caching layer that sits between your
computation and the batch executors:

- **Cross-batch result caching** — identical queries across batch rounds return
  cached results without re-executing
- **Within-batch request deduplication** — identical queries in the same batch
  round are sent to the executor only once, with the result fanned out to all
  requesting fibers

### Wiring with Cache

Use `QueryCache.with_executor/3` or `QueryCache.with_executors/2` instead of
`Contract.with_executor/2`:

```elixir
alias Skuld.Query.Cache, as: QueryCache

# Single contract
my_comp
|> QueryCache.with_executor(MyApp.Queries.Users, MyApp.Queries.Users.EctoExecutor)
|> FiberPool.with_handler()
|> FiberPool.run()

# Multiple contracts (shared cache scope)
my_comp
|> QueryCache.with_executors([
  {MyApp.Queries.Users, MyApp.Queries.Users.EctoExecutor},
  {MyApp.Queries.Orders, MyApp.Queries.Orders.EctoExecutor}
])
|> FiberPool.with_handler()
|> FiberPool.run()
```

### Cache Scope and Lifetime

The cache is scoped per computation run. It's initialised as an empty map when
`with_executors` sets up the scope, and cleaned up on scope exit. No TTL, no
eviction — the cache lives exactly as long as the computation.

This matches Haxl's per-`Env` cache semantics: within a single request/computation,
you get automatic deduplication and caching, with no stale data concerns.

### Cache Keys

Cache keys are `{batch_key, op_struct}` where:
- `batch_key` is `{ContractModule, :query_name}` (e.g., `{Users, :get_user}`)
- `op_struct` is the operation struct (e.g., `%Users.GetUser{id: "123"}`)

Structural equality on Elixir structs provides correct comparison. Two queries
with the same parameters share a cache entry.

### Per-Query Opt-Out

Mark individual queries as non-cacheable with `cache: false`:

```elixir
defmodule MyApp.Queries.Users do
  use Skuld.Query.Contract

  deffetch get_user(id :: String.t()) :: User.t() | nil
  deffetch get_random_user() :: User.t(), cache: false
end
```

Non-cacheable queries bypass the cache entirely — they always go to the executor.

### Error Handling

Executor failures are **not cached**. When an executor returns a Throw/error:
- The error propagates normally to requesting fibers
- Nothing is stored in the cache
- Subsequent requests for the same query go to the executor again

## How Batching Works

Under the hood, the query system uses FiberPool's batch suspension mechanism:

1. Each caller function (e.g., `get_user/1`) creates an `InternalSuspend.batch`
   with a batch key of `{ContractModule, :query_name}` and an operation struct
2. The FiberPool scheduler collects batch-suspended fibers
3. When the run queue empties, the scheduler groups suspensions by batch key
4. For each group, the registered executor callback runs with all ops
5. Results are distributed back to the waiting fibers via the `request_id` map

The programmer writes simple per-record fetch calls. Batching happens automatically
when multiple fibers make the same type of fetch concurrently.

### Manual FiberPool Composition

For cases where the `query` macro isn't suitable, you can compose fetches
manually using FiberPool primitives:

```elixir
# Using FiberPool.map for collections
FiberPool.map(["1", "2", "3"], &Users.get_user/1)
|> Users.with_executor(Users.EctoExecutor)
|> FiberPool.with_handler()
|> FiberPool.run!()
# All 3 get_user calls batched into a single executor invocation

# Using fiber/await for individual control
comp do
  h1 <- FiberPool.fiber(Users.get_user("1"))
  h2 <- FiberPool.fiber(Users.get_user("2"))
  h3 <- FiberPool.fiber(Users.get_user("3"))
  FiberPool.await_all!([h1, h2, h3])
end
```

## Testing

For tests, implement a stub executor:

```elixir
defmodule MyApp.Queries.Users.TestExecutor do
  use Skuld.Syntax

  @behaviour MyApp.Queries.Users.Executor

  alias MyApp.Queries.Users.{GetUser, GetUsersByOrg}

  @impl true
  defcomp get_user(ops) do
    Map.new(ops, fn {ref, %GetUser{id: id}} ->
      {ref, %User{id: id, name: "Test User #{id}"}}
    end)
  end

  @impl true
  defcomp get_users_by_org(ops) do
    Map.new(ops, fn {ref, %GetUsersByOrg{org_id: _}} ->
      {ref, []}
    end)
  end

  # ...
end
```

Or use inline anonymous executors for one-off tests (register directly with
`BatchExecutor.with_executor/3`):

```elixir
alias Skuld.Fiber.FiberPool.BatchExecutor

query do
  user <- Users.get_user("1")
  user
end
|> BatchExecutor.with_executor(
  {Users, :get_user},
  fn ops ->
    Comp.pure(Map.new(ops, fn {ref, _op} -> {ref, %User{id: "1", name: "Stubbed"}} end))
  end
)
|> FiberPool.with_handler()
|> FiberPool.run!()
```

## Comparison with Port.Contract

| Aspect | Port.Contract | Query.Contract |
|--------|--------------|----------------|
| Purpose | Blocking calls to external code | Batchable queries across fibers |
| Execution | One call at a time | Multiple calls batched together |
| Requires FiberPool | No | Yes |
| Executor receives | Single call args | List of `{ref, op_struct}` |
| Executor returns | Single result | `%{ref => result}` map |
| Macro | `defport` | `deffetch` |
| Bang variants | Same rules | Same rules |
| Handler installation | `Port.with_handler/2` | `Contract.with_executor/2` |
| Composition | `comp do` (sequential) | `query do` (auto-concurrent) |

## Absinthe Integration

Skuld's query system is a natural fit for GraphQL resolvers, where the N+1
problem is pervasive. Absinthe (the Elixir GraphQL library) already has a
plugin-based solution for this — `Absinthe.Middleware.Dataloader` — and Skuld
could integrate using the same extension points.

### How Absinthe Batching Works

Absinthe's resolution pipeline supports **suspension-based batching** through
the `Absinthe.Plugin` behaviour:

1. **Resolve fields** — Absinthe walks the query tree, calling each field's
   resolver
2. **Suspend** — A resolver that needs batched data returns a middleware tuple
   that sets the field's state to `:suspended` and queues a load
3. **Batch** — After the walk, plugins get a `before_resolution` callback to
   execute accumulated batches
4. **Re-run** — If the plugin's `pipeline/2` callback detects pending work,
   Absinthe re-inserts the Resolution phase and walks the tree again, this
   time delivering results to suspended fields
5. **Repeat** — This loop continues until no plugin requests another pass

This is exactly how `Absinthe.Middleware.Dataloader` works — it implements both
`Absinthe.Middleware` (to suspend/resume individual fields) and
`Absinthe.Plugin` (to run batches between passes).

### Integration Strategy

A Skuld integration would follow the same pattern, implementing both
behaviours:

```elixir
defmodule Skuld.Absinthe.Plugin do
  @behaviour Absinthe.Middleware
  @behaviour Absinthe.Plugin

  # Middleware: queue a deffetch operation and suspend the field
  def call(%{state: :unresolved} = res, {skuld_ctx, callback}) do
    %{res |
      state: :suspended,
      middleware: [{__MODULE__, callback} | res.middleware],
      context: Map.put(res.context, :skuld, skuld_ctx)}
  end

  # Middleware: field was suspended, data now available — resolve it
  def call(%{state: :suspended} = res, callback) do
    result = callback.(res.context.skuld)
    Absinthe.Resolution.put_result(res, {:ok, result})
  end

  # Plugin: run Skuld batches between resolution passes
  def before_resolution(%{context: %{skuld: ctx}} = exec) do
    # Execute queued deffetch operations through FiberPool
    %{exec | context: Map.put(exec.context, :skuld, run_batches(ctx))}
  end

  # Plugin: re-run resolution if there are still pending batches
  def pipeline(pipeline, exec) do
    if has_pending?(exec.context.skuld) do
      [Absinthe.Phase.Document.Execution.Resolution | pipeline]
    else
      pipeline
    end
  end
end
```

The key challenge is bridging Absinthe's imperative suspension model (set state,
re-walk tree) with Skuld's functional effect model (fiber suspension, `Comp.bind`
chains). The plugin would need to collect `deffetch` operation structs during
resolution, then run them through a Skuld computation (with FiberPool and batch
executors) in `before_resolution`, and store results for retrieval on the next
pass.

> **Status:** Absinthe integration is not yet implemented. The architecture is
> compatible — Absinthe's plugin system was designed for exactly this kind of
> extension — but the bridging code needs to be written. See the issue tracker
> for progress.
