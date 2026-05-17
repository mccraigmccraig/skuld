# Batch Loading

<!-- nav:header:start -->
[< The Decider Pattern](decider-pattern.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [How It Works >](../internals.md)
<!-- nav:header:end -->

Eliminate N+1 queries with `deffetch` operations and `FiberPool`.

Each `deffetch` call suspends the current fiber, signalling the scheduler
to hold the request. `FiberPool` collects suspended fetch calls across
*all* concurrent fibers and dispatches them in batches to your executor.
Within a `query do` block, dependency
analysis adds automatic concurrency for independent fetches. Together
they eliminate N+1 queries without restructuring code.

In the example below, `build_summary` expresses domain logic with very
little ceremony. When it runs, the system provides concurrency at two
levels: within each query block (`fetch_user` and `fetch_orders` run
together), and globally — `deffetch` calls from all concurrent
invocations are batched into single round-trips.

## The N+1 problem

```elixir
# N+1: one query for users, then N queries for their orders
users <- Repo.all(User)
Enum.map(users, fn user ->
  {:ok, orders} <- Repo.get_by(Order, user_id: user.id)
  {user, orders}
end)
```

## The solution: `query do` with streaming

Define fetch operations with `deffetch`:

```elixir
defmodule AccountQueries do
  use Skuld.Query

  deffetch fetch_user(id :: String.t()) :: User.t() | nil
  deffetch fetch_orders(user_id :: String.t()) :: [Order.t()]
  deffetch fetch_order_details(order_id :: String.t()) :: [OrderDetail.t()]
end
```

Build a summary for one user. The `query` block automatically batches
calls across concurrent transforms. `Query.map` spawns each detail fetch
as a fiber so they batch together:

```elixir
defquery build_summary(user_id, month) do
  user <- AccountQueries.fetch_user(user_id)
  orders <- AccountQueries.fetch_orders(user_id, month)
  order_ids = Enum.map(orders, & &1.id)

  details_list <- Query.map(order_ids, &AccountQueries.fetch_order_details/1)

  build_summary(user, orders, details_list)
end
```

Feed a stream of user IDs through `Brook.map` with concurrency.
The query system batches `deffetch` calls from *all* concurrent
transforms together:

```elixir
comp do
  source <- Brook.from_enum(user_ids, buffer: 20)

  summaries <-
    Brook.map(
      source,
      fn user_id -> build_summary(user_id, "2026-01") end,
      concurrency: 4
    )

  Brook.to_list(summaries)
end
|> Skuld.Query.with_executor(AccountQueries, AccountExecutor)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

## What happens

With `concurrency: 4`, the FiberPool runs 4 transforms concurrently.
As each transform calls `fetch_user(user_id)`, the query system holds
the call and waits for other transforms to reach their first fetch.
When enough calls accumulate, they're batched into a single round-trip:

- **10 users, concurrency 4**: `fetch_user` calls arrive in batches
  of [4, 4, 2]. Same for `fetch_orders`.
- **5 users, concurrency 1**: each batch has only 1 call — no
  batching benefit.

Dependent calls (like `fetch_order_details` which depends on
`orders` from the previous fetch) wait for their inputs and run in
subsequent rounds.

## Wiring an executor

```elixir
defmodule AccountExecutor do
  @behaviour AccountQueries

  @impl true
  def fetch_user(ops) do
    results = ops |> Enum.map(fn {_ref, op} -> op end) |> BulkAPI.bulk_fetch_users()
    Map.new(ops, fn {ref, op} -> {ref, Map.fetch!(results, op)} end)
  end

  @impl true
  def fetch_orders(ops) do
    results = ops |> Enum.map(fn {_ref, op} -> op end) |> BulkAPI.bulk_fetch_orders()
    Map.new(ops, fn {ref, op} -> {ref, Map.fetch!(results, op)} end)
  end
end
```

Each executor method receives a *list* of `{ref, op}` tuples — all the
calls that were batched together. Return a map keyed by ref.

## How it works

`query do` blocks desugar into `deffetch` calls with dependency analysis.
Independent operations are held and dispatched in batches via `FiberPool`.
Dependent operations wait for their inputs and run in subsequent rounds.
The result is automatic N+1 elimination — no manual batching, no data
loader boilerplate, no code restructuring.

<!-- nav:footer:start -->

---

[< The Decider Pattern](decider-pattern.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [How It Works >](../internals.md)
<!-- nav:footer:end -->
