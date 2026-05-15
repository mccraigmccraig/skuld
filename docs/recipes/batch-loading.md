# Batch Loading

<!-- nav:header:start -->
[< The Decider Pattern](decider-pattern.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [How It Works >](../internals.md)
<!-- nav:header:end -->

Eliminate N+1 queries with `query do` blocks. The query system analyzes
effect dependencies and batches independent data fetches together — no
code restructuring needed.

## The N+1 problem

```elixir
# N+1: one query for users, then one per user for subscriptions
users <- Repo.all(User)
Enum.map(users, fn user ->
  {:ok, sub} <- Repo.get_by(Subscription, user_id: user.id)
  {user, sub}
end)
```

## The solution: `query do`

```elixir
defmodule MyApp.Fetches do
  use Skuld.Query

  deffetch get_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()}
  deffetch get_subscription(user_id :: String.t()) :: {:ok, Subscription.t()} | {:error, term()}
end

defcomp load_dashboard(user_id) do
  query do
    user <- MyApp.Fetches.get_user(user_id)
    sub <- MyApp.Fetches.get_subscription(user.id)
    {:ok, %{user: user, subscription: sub}}
  end
end
```

The query system detects that `get_subscription` depends on `user.id` and
batches any *independent* `get_user` calls together. Dependent fetches
run in a second round.

## Wiring executors

```elixir
defmodule MyApp.UserExecutor do
  @behaviour Skuld.Query.Executor

  def execute(tagged_ops) do
    results = for {ref, op} <- tagged_ops, into: %{} do
      {ref, do_fetch(op)}
    end
    {:ok, results}
  end
end

load_dashboard("user-123")
|> Skuld.Query.with_executor(MyApp.Fetches, MyApp.UserExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
```

## Caching

Within-batch deduplication:

```elixir
load_dashboard("user-123")
|> Skuld.Query.with_cached_executor(MyApp.Fetches, MyApp.UserExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
```

If `get_user("user-123")` is called twice in the same batch, the second
call returns the cached result.

## Multiple contracts

Wire multiple fetch contracts together:

```elixir
computation
|> Skuld.Query.with_cached_executors([
  {MyApp.Fetches, MyApp.UserExecutor},
  {MyApp.Products, MyApp.ProductExecutor}
])
|> FiberPool.with_handler()
|> Comp.run!()
```

## How it works

`query do` blocks desugar into `deffetch` calls with dependency analysis.
Independent operations are batched and executed concurrently via
`FiberPool` fibers. Dependent operations wait for their inputs and run in
subsequent rounds. The result is automatic N+1 elimination without
manual batching or data loader boilerplate.

<!-- nav:footer:start -->

---

[< The Decider Pattern](decider-pattern.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [How It Works >](../internals.md)
<!-- nav:footer:end -->
