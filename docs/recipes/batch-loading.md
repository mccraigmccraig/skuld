# Batch Loading

<!-- nav:header:start -->
[< Durable Computation](durable-computation.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [How It Works >](../internals.md)
<!-- nav:header:end -->

Eliminate N+1 queries with `deffetch` operations and `FiberPool`.

Each `deffetch` call suspends the current fiber, signalling the scheduler
to hold the request. `FiberPool` collects suspended fetch calls across
*all* concurrent fibers and dispatches them in batches to your executor.
Within a `query do` block, dependency
analysis adds automatic concurrency for independent fetches. Together
they eliminate N+1 queries without restructuring code.

In the example below, `build_account_summary` expresses domain logic with very
little ceremony. When it runs, the system provides concurrency at two
levels: within each query block (`fetch_user` and `fetch_orders` run
together), and globally — `deffetch` calls from all concurrent
invocations are batched into single round-trips.

## The N+1 problem

Each user has orders, and each order has line items. A naive approach walks
the tree row-by-row:

```elixir
# 1 + N + (N * M): one query for users, then N for orders, then N * M for details
users <- Repo.all(User)
Enum.map(users, fn user ->
  {:ok, orders} <- Repo.get_by(Order, user_id: user.id)

  orders_with_details =
    Enum.map(orders, fn order ->
      {:ok, details} <- Repo.get_by(OrderDetail, order_id: order.id)
      Map.put(order, :details, details)
    end)

  {user, orders_with_details}
end)
```

A conventional bulk approach flattens the problem into a single streaming
query — join users to orders to details in one pass, or preload the
associations:

```elixir
# Single streaming query with joins — no N+1, but couples queries to shape
from(u in User,
  join: o in Order, on: o.user_id == u.id,
  join: d in OrderDetail, on: d.order_id == o.id,
  select: {u, o, d}
)
|> Repo.stream()
|> Stream.chunk_by(&elem(&1, 0))
|> Enum.map(fn [{user, _, _} | _] = rows ->
  orders = Enum.map(rows, fn {_, order, detail} ->
    order |> Map.put(:details, [detail])
  end)
  {user, orders}
end)
```

This works well when you have Ecto and SQL — the query planner does the
heavy lifting. But it couples your domain logic to a specific query shape
and relies on relational joins. When your data lives behind REST APIs,
gRPC services, or other storage that supports bulk-by-id lookups, Skuld's
approach gives you the same batching benefit without the coupling.

## Another solution: `query do` with streaming

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
defquery build_account_summary(user_id, month) do
  user <- AccountQueries.fetch_user(user_id)
  orders <- AccountQueries.fetch_orders(user_id, month)
  order_ids = Enum.map(orders, & &1.id)

  details_list <- Query.map(order_ids, &AccountQueries.fetch_order_details/1)

  make_account_summary(user, orders, details_list)
end
```

Feed a stream of user IDs through `Brook.map` with concurrency.
The query system batches together calls of the same `deffetch` function from
*all* concurrent `build_account_summary` transforms:

```elixir
defcomp build_account_summaries(user_ids_source, month) do
  concurrency <- Reader.ask(AccountQueries.Concurrency)

  Brook.map(
    user_ids_source,
    &build_account_summary(&1, month),
    concurrency: concurrency
  )
end

comp do
  user_ids_source <- Brook.from_enum(user_ids, buffer: 20)
  summaries <- build_account_summaries(user_ids_source, "2026-01")
  Brook.to_list(summaries)
end
|> Skuld.Query.with_executor(AccountQueries, AccountExecutor)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

## What happens

With `concurrency: 4`, the FiberPool runs 4 `build_account_summary` transforms concurrently.
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

[< Durable Computation](durable-computation.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [How It Works >](../internals.md)
<!-- nav:footer:end -->
