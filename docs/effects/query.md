# Query System

<!-- nav:header:start -->
[< Repo](repo.md) | [Index](../../README.md)
<!-- nav:header:end -->

Automatic N+1 query batching via dependency analysis. The query system
analyzes effect dependencies in a `query do` block and batches independent
data fetches together — using FiberPool fibers to execute them concurrently.

## Defining fetch operations

```elixir
defmodule MyApp.Users do
  use Skuld.Query

  deffetch get_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()}
  deffetch get_subscription(user_id :: String.t()) :: {:ok, Subscription.t()} | {:error, term()}
end
```

## Wiring executors

An executor handles a batch of operations:

```elixir
defmodule MyApp.UserExecutor do
  @behaviour Skuld.Query.Executor

  def execute(tagged_ops) do
    # tagged_ops = [{ref, %GetUser{id: id}}, ...]
    # Return results keyed by ref
    results = for {ref, op} <- tagged_ops, into: %{} do
      {ref, Repo.get!(User, op.id)}
    end
    {:ok, results}
  end
end

Skuld.Query.with_executor(MyApp.Users, MyApp.UserExecutor)
```

## Query blocks

A `query do` block expresses data dependencies naturally. The system
analyzes them and batches independent fetches:

```elixir
comp do
  query do
    user <- MyApp.Users.get_user(user_id)
    sub <- MyApp.Users.get_subscription(user.id)
    {:ok, %{user: user, subscription: sub}}
  end
end
|> Skuld.Query.with_executor(MyApp.Users, MyApp.UserExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
```

Even though `get_subscription` depends on `user.id`, any other
`get_user` calls in the block that are independent will be batched
together.

## Caching

Within-batch deduplication via `Skuld.Query.Cache`:

```elixir
computation
|> Skuld.Query.with_cached_executor(MyApp.Users, MyApp.UserExecutor)
|> FiberPool.with_handler()
```

If the same `get_user("123")` is called twice in a batch, the second
call hits the cache instead of the executor.

| Function | Purpose |
|----------|---------|
| `deffetch` | Declare a fetch operation |
| `query do` block | Express data dependencies, auto-batch independent fetches |
| `with_executor/2,3` | Wire a contract to an executor |
| `with_cached_executor/2,3` | Wire with within-batch caching |
| `with_cached_executors/2` | Wire multiple contracts |

<!-- nav:footer:start -->

---

[< Repo](repo.md) | [Index](../../README.md)
<!-- nav:footer:end -->
