# Batch Data Loading

Skuld's query system eliminates N+1 queries by automatically batching
concurrent fetch calls. You write simple per-record code; the runtime
combines concurrent calls of the same type into a single query.

## Quick setup

### 1. Define a query contract

```elixir
defmodule MyApp.Queries do
  use Skuld.Query.Contract

  deffetch get_user(id :: String.t()) :: User.t() | nil
  deffetch get_orders(user_id :: String.t()) :: [Order.t()]
  deffetch get_profile(user_id :: String.t()) :: Profile.t() | nil
end
```

### 2. Implement an executor

```elixir
defmodule MyApp.Queries.EctoExecutor do
  use Skuld.Syntax
  @behaviour MyApp.Queries.Executor

  @impl true
  defcomp get_user(ops) do
    ids = ops |> Enum.map(fn {_, %MyApp.Queries.GetUser{id: id}} -> id end) |> Enum.uniq()
    users = Repo.all(from u in User, where: u.id in ^ids)
    by_id = Map.new(users, &{&1.id, &1})
    Map.new(ops, fn {ref, %{id: id}} -> {ref, Map.get(by_id, id)} end)
  end

  @impl true
  defcomp get_orders(ops) do
    user_ids = ops |> Enum.map(fn {_, %{user_id: uid}} -> uid end) |> Enum.uniq()
    orders = Repo.all(from o in Order, where: o.user_id in ^user_ids)
    grouped = Enum.group_by(orders, & &1.user_id)
    Map.new(ops, fn {ref, %{user_id: uid}} -> {ref, Map.get(grouped, uid, [])} end)
  end

  @impl true
  defcomp get_profile(ops) do
    user_ids = ops |> Enum.map(fn {_, %{user_id: uid}} -> uid end) |> Enum.uniq()
    profiles = Repo.all(from p in Profile, where: p.user_id in ^user_ids)
    by_uid = Map.new(profiles, &{&1.user_id, &1})
    Map.new(ops, fn {ref, %{user_id: uid}} -> {ref, Map.get(by_uid, uid)} end)
  end
end
```

### 3. Use in computations

```elixir
# Simple: fetch multiple users
FiberPool.map(user_ids, &MyApp.Queries.get_user/1)
|> MyApp.Queries.with_executor(MyApp.Queries.EctoExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
# All get_user calls batched into one query
```

## The `query` macro for automatic concurrency

When fetches are independent, `query` runs them concurrently:

```elixir
defcomp load_dashboard(user_id) do
  query do
    user <- MyApp.Queries.get_user(user_id)
    orders <- MyApp.Queries.get_orders(user_id)
    profile <- MyApp.Queries.get_profile(user_id)
    %{user: user, orders: orders, profile: profile}
  end
end
```

All three fetches are independent, so `query` runs them in parallel
fibers. If other fibers are also running `get_user` calls, they all
batch together.

## Nested fetches

Fetches can be nested - the batching works across all concurrent fibers
regardless of call depth:

```elixir
defcomp user_with_details(user_id) do
  user <- MyApp.Queries.get_user(user_id)
  orders <- MyApp.Queries.get_orders(user_id)
  profile <- MyApp.Queries.get_profile(user_id)
  %{user: user, orders: orders, profile: profile}
end

# Load 100 users with all their details
FiberPool.map(user_ids, &user_with_details/1)
|> MyApp.Queries.with_executor(MyApp.Queries.EctoExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
# 3 batched queries total (users, orders, profiles)
# instead of 300 individual queries
```

## Adding caching

Wrap with `Query.Cache` for cross-batch deduplication:

```elixir
alias Skuld.Query.Cache, as: QueryCache

FiberPool.map(user_ids, &user_with_details/1)
|> QueryCache.with_executor(MyApp.Queries, MyApp.Queries.EctoExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
```

If user "u1" is fetched in batch 1 and again in batch 2, the second
fetch returns the cached result without hitting the executor. Cache
lives for the duration of the computation run - no stale data.

## Testing

Use a stub executor:

```elixir
defmodule MyApp.Queries.TestExecutor do
  use Skuld.Syntax
  @behaviour MyApp.Queries.Executor

  @impl true
  defcomp get_user(ops) do
    Map.new(ops, fn {ref, %{id: id}} ->
      {ref, %User{id: id, name: "Test User #{id}"}}
    end)
  end

  # ... other callbacks
end
```

Or inline for one-off tests:

```elixir
alias Skuld.Fiber.FiberPool.BatchExecutor

my_comp
|> BatchExecutor.with_executor(
  {MyApp.Queries, :get_user},
  fn ops ->
    Comp.pure(Map.new(ops, fn {ref, %{id: id}} ->
      {ref, %User{id: id, name: "Stub"}}
    end))
  end
)
|> FiberPool.with_handler()
|> Comp.run!()
```

## When batching helps

Batching is most effective when:

- Multiple concurrent fibers make the same type of query
- Queries can be efficiently combined (SQL `IN` clauses, batch APIs)
- The overhead of individual queries exceeds the overhead of batching

It's less useful for:

- Single queries (nothing to batch with)
- Queries that can't be combined (complex joins, aggregations)
- CPU-bound computation (no I/O to batch)
