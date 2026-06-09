# Query System

<!-- nav:header:start -->
[Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Two complementary mechanisms for data fetching. Together they eliminate
N+1 queries, but each stands alone. Inspired by Facebook's
[Haxl](https://github.com/facebook/Haxl) library.

## Query.Contract — batchable fetch operations

`deffetch` declares typed fetch operations that suspend the current
fiber for batched execution. Each generated caller returns a computation
with an `InternalSuspend.batch` sentinel, which `FiberPool` recognises
and dispatches to the configured executor as a batch:

```elixir
defmodule MyApp.Users do
  use Skuld.Query

  deffetch get_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()}
  deffetch get_subscription(user_id :: String.t()) :: {:ok, Subscription.t()} | {:error, term()}
end
```

Wiring an executor:

```elixir
defmodule MyApp.UserExecutor do
  @behaviour Skuld.Query.Executor

  def execute(tagged_ops) do
    results = for {ref, op} <- tagged_ops, into: %{} do
      {ref, Repo.get!(User, op.id)}
    end
    {:ok, results}
  end
end

computation
|> Skuld.Query.with_executor(MyApp.Users, MyApp.UserExecutor)
|> FiberPool.with_handler()
|> Comp.run!()
```

Used standalone, `Query.Contract` enables N+1 elimination anywhere
`FiberPool` is installed — multiple fibers calling the same `deffetch`
get their calls batched by the scheduler.

## `query do` — concurrent effect execution

A `query` block analyzes dependencies between expressions and batches
independent ones for concurrent execution via `FiberPool` fibers:

```elixir
comp do
  query do
    user <- MyApp.Users.get_user(user_id)
    recent <- MyApp.Posts.get_recent()               # runs concurrently with ↑
    sub <- MyApp.Users.get_subscription(user.id)
    {:ok, %{user: user, recent: recent, subscription: sub}}
  end
end
|> Skuld.Query.with_executors([
  {MyApp.Users, MyApp.UserExecutor},
  {MyApp.Posts, MyApp.PostExecutor}
])
|> FiberPool.with_handler()
|> Comp.run!()
```

`get_user(user_id)` and `get_recent()` are independent — they run
concurrently. `get_subscription(user.id)` depends on `user`, so it runs
in a second round after the first batch completes.

`query` blocks don't require `deffetch` — any effectful computation
can appear in a `query` block. The dependency analysis and concurrent
dispatch work the same way.

## Caching

Within-batch deduplication via `Skuld.Query.Cache`:

```elixir
computation
|> Skuld.Query.with_cached_executor(MyApp.Users, MyApp.UserExecutor)
|> FiberPool.with_handler()
```

| Function | Purpose |
|----------|---------|
| `deffetch` | Declare a batchable fetch operation |
| `query do` block | Concurrent effect execution with dependency analysis |
| `with_executor/2,3` | Wire a contract to an executor |
| `with_cached_executor/2,3` | Wire with within-batch caching |
| `with_cached_executors/2` | Wire multiple contracts |

<!-- nav:footer:start -->

---

[Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
