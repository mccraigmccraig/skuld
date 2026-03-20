# Query.Contract

`Query.Contract` is a typed DSL for declaring batchable query operations. It solves
the N+1 query problem by transparently batching concurrent query calls across FiberPool
fibers, while providing full type safety, LSP completion, and Dialyzer verification.

Where `Port.Contract` wraps blocking calls to external code (one call at a time),
`Query.Contract` wraps queries that benefit from batching — multiple concurrent callers
suspend, and when the run queue empties, the scheduler groups their operations by query
type and executes a single batched call per group.

## Overview

A Query contract defines a set of query operations using `defquery` declarations.
The macro generates:

- **Operation structs** — nested struct modules per query (e.g., `MyContract.GetUser`)
- **Caller functions** — typed public API that suspends the current fiber for batching
- **Executor behaviour** (`MyContract.Executor`) — typed callbacks, one per query
- **Dispatch function** — `__dispatch__/3` routes from batch key to executor callback
- **Wiring function** — `with_executor/2` installs an executor for all queries
- **Bang variants** — unwrap `{:ok, v}` or dispatch Throw (when applicable)
- **Introspection** — `__query_operations__/0` returns metadata

## Defining a Contract

```elixir
defmodule MyApp.Queries.Users do
  use Skuld.Query.Contract

  defquery get_user(id :: String.t()) :: User.t() | nil
  defquery get_users_by_org(org_id :: String.t()) :: [User.t()]
  defquery get_user_count(org_id :: String.t()) :: non_neg_integer()
end
```

Each `defquery` follows the same syntax as `Port.Contract`'s `defport`:

```
defquery function_name(param :: type(), ...) :: return_type()
defquery function_name(param :: type(), ...) :: return_type(), bang: option
```

### What Gets Generated

For the contract above, the macro generates:

**Operation structs** — one per query, PascalCased, nested inside the contract module:

```elixir
defmodule MyApp.Queries.Users.GetUser do
  @moduledoc false
  defstruct [:id]
  @type t :: %__MODULE__{id: String.t()}
end

defmodule MyApp.Queries.Users.GetUsersByOrg do
  @moduledoc false
  defstruct [:org_id]
  @type t :: %__MODULE__{org_id: String.t()}
end
```

**Caller functions** — typed, suspending the fiber for batched execution:

```elixir
@spec get_user(String.t()) :: Skuld.Comp.Types.computation(User.t() | nil)
def get_user(id)

@spec get_users_by_org(String.t()) :: Skuld.Comp.Types.computation([User.t()])
def get_users_by_org(org_id)
```

**Executor behaviour** — `MyApp.Queries.Users.Executor` with typed callbacks:

```elixir
@callback get_user(ops :: [{reference(), GetUser.t()}]) ::
  Skuld.Comp.Types.computation(%{reference() => User.t() | nil})

@callback get_users_by_org(ops :: [{reference(), GetUsersByOrg.t()}]) ::
  Skuld.Comp.Types.computation(%{reference() => [User.t()]})
```

Each callback receives a list of `{request_id, op_struct}` tuples and returns a
computation yielding `%{request_id => result}`. The ops list is homogeneous per
callback — strongly typed, Dialyzer-checked.

## Implementing an Executor

An executor implements the generated behaviour with one callback per query:

```elixir
defmodule MyApp.Queries.Users.EctoExecutor do
  @behaviour MyApp.Queries.Users.Executor

  alias Skuld.Comp
  alias Skuld.Effects.Reader
  alias MyApp.Queries.Users.{GetUser, GetUsersByOrg, GetUserCount}

  @impl true
  def get_user(ops) do
    # Extract unique IDs from all batched operations
    ids = Enum.map(ops, fn {_ref, %GetUser{id: id}} -> id end) |> Enum.uniq()

    Comp.bind(Reader.ask(:repo), fn repo ->
      results = repo.all(from u in User, where: u.id in ^ids)
      by_id = Map.new(results, &{&1.id, &1})

      # Map results back to request IDs
      Comp.pure(Map.new(ops, fn {ref, %GetUser{id: id}} ->
        {ref, Map.get(by_id, id)}
      end))
    end)
  end

  @impl true
  def get_users_by_org(ops) do
    org_ids = Enum.map(ops, fn {_ref, %GetUsersByOrg{org_id: oid}} -> oid end) |> Enum.uniq()

    Comp.bind(Reader.ask(:repo), fn repo ->
      results = repo.all(from u in User, where: u.org_id in ^org_ids)
      grouped = Enum.group_by(results, & &1.org_id)

      Comp.pure(Map.new(ops, fn {ref, %GetUsersByOrg{org_id: oid}} ->
        {ref, Map.get(grouped, oid, [])}
      end))
    end)
  end

  @impl true
  def get_user_count(ops) do
    org_ids = Enum.map(ops, fn {_ref, %GetUserCount{org_id: oid}} -> oid end) |> Enum.uniq()

    Comp.bind(Reader.ask(:repo), fn repo ->
      counts =
        repo.all(from u in User, where: u.org_id in ^org_ids,
          group_by: u.org_id, select: {u.org_id, count(u.id)})
        |> Map.new()

      Comp.pure(Map.new(ops, fn {ref, %GetUserCount{org_id: oid}} ->
        {ref, Map.get(counts, oid, 0)}
      end))
    end)
  end
end
```

The pattern is always the same:
1. Extract unique parameter values from the batched ops
2. Execute a single query covering all values
3. Map results back to `%{request_id => result}`

Since executor callbacks return computations, they can use any Skuld effect
(Reader, State, DB, Port, etc.).

## Wiring

Install an executor for a contract using `with_executor/2`:

```elixir
use Skuld.Syntax
alias Skuld.Effects.FiberPool

comp do
  h1 <- FiberPool.fiber(MyApp.Queries.Users.get_user("1"))
  h2 <- FiberPool.fiber(MyApp.Queries.Users.get_user("2"))
  h3 <- FiberPool.fiber(MyApp.Queries.Users.get_user("3"))

  FiberPool.await_all!([h1, h2, h3])
end
|> MyApp.Queries.Users.with_executor(MyApp.Queries.Users.EctoExecutor)
|> Reader.with_handler(MyApp.Repo, tag: :repo)
|> FiberPool.with_handler()
|> FiberPool.run!()
# All 3 get_user calls batched into a single executor invocation
```

`with_executor/2` registers the executor for *all* queries in the contract. Each
query type batches independently — `get_user` calls batch together, `get_users_by_org`
calls batch together, but they don't mix.

### Bulk Wiring

For applications with multiple contracts, use `Skuld.Query.Contract.with_executors/2`
to install all executors in one call:

```elixir
comp
|> Skuld.Query.Contract.with_executors([
  {MyApp.Queries.Users, MyApp.Queries.Users.EctoExecutor},
  {MyApp.Queries.Orders, MyApp.Queries.Orders.EctoExecutor}
])
```

Also accepts a map:

```elixir
comp
|> Skuld.Query.Contract.with_executors(%{
  MyApp.Queries.Users => MyApp.Queries.Users.EctoExecutor,
  MyApp.Queries.Orders => MyApp.Queries.Orders.EctoExecutor
})
```

## How Batching Works

1. Each caller function (e.g., `get_user/1`) creates an `InternalSuspend.batch`
   with a batch key of `{ContractModule, :query_name}` and an operation struct
2. The FiberPool scheduler collects batch-suspended fibers
3. When the run queue empties, the scheduler groups suspensions by batch key
4. For each group, the registered executor callback runs with all ops
5. Results are distributed back to the waiting fibers via the `request_id` map

The programmer writes simple per-record query calls. Batching happens automatically
when multiple fibers make the same type of query concurrently.

## Bang Variants

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
  defquery find_account(id :: String.t()) :: {:ok, Account.t()} | {:error, term()}
  # Generated: find_account!/1 returning computation(Account.t())

  # No {:ok, T} pattern -> no bang
  defquery get_account(id :: String.t()) :: Account.t() | nil
  # No bang generated

  # Force bang
  defquery lookup_account(id :: String.t()) :: Account.t() | nil, bang: true

  # Suppress bang
  defquery search_accounts(q :: String.t()) :: {:ok, [Account.t()]} | {:error, term()},
    bang: false

  # Custom unwrap
  defquery fetch_account(id :: String.t()) :: map(),
    bang: fn result -> {:ok, result} end
end
```

## Introspection

Every contract module provides `__query_operations__/0` returning metadata:

```elixir
MyApp.Queries.Users.__query_operations__()
#=> [
#     %{name: :get_user, params: [:id], param_types: [...], return_type: ..., arity: 1},
#     %{name: :get_users_by_org, params: [:org_id], param_types: [...], return_type: ..., arity: 1},
#     %{name: :get_user_count, params: [:org_id], param_types: [...], return_type: ..., arity: 1}
#   ]
```

And `__dispatch__/3` for programmatic routing:

```elixir
MyApp.Queries.Users.__dispatch__(executor_module, :get_user, ops)
# Equivalent to: executor_module.get_user(ops)
```

## Testing

For tests, implement a stub executor:

```elixir
defmodule MyApp.Queries.Users.TestExecutor do
  @behaviour MyApp.Queries.Users.Executor

  alias Skuld.Comp
  alias MyApp.Queries.Users.{GetUser, GetUsersByOrg}

  @impl true
  def get_user(ops) do
    Comp.pure(Map.new(ops, fn {ref, %GetUser{id: id}} ->
      {ref, %User{id: id, name: "Test User #{id}"}}
    end))
  end

  @impl true
  def get_users_by_org(ops) do
    Comp.pure(Map.new(ops, fn {ref, %GetUsersByOrg{org_id: _}} ->
      {ref, []}
    end))
  end

  # ...
end
```

Or use inline anonymous executors for one-off tests (register directly with
`BatchExecutor.with_executor/3`):

```elixir
alias Skuld.Fiber.FiberPool.BatchExecutor

comp do
  h <- FiberPool.fiber(MyApp.Queries.Users.get_user("1"))
  FiberPool.await!(h)
end
|> BatchExecutor.with_executor(
  {MyApp.Queries.Users, :get_user},
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
| Macro | `defport` | `defquery` |
| Bang variants | Same rules | Same rules |
| Handler installation | `Port.with_handler/2` | `Contract.with_executor/2` |
