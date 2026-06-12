# skuld_query

<!-- nav:header:start -->
[Query System >](docs/effects/query.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Haxl-style auto-batching for Skuld — write sequential-looking data fetch
code, get automatic concurrency and batching. `query do` blocks analyze
variable dependencies, group independent fetches, and dispatch them
concurrently through the FiberPool scheduler.

## What's included

- **`Skuld.Query`** — `query`, `defquery`, and `defqueryp` macros. Write
  sequential code; the macro builds a dependency graph and emits
  concurrent fiber batches for independent operations.
- **`Skuld.QueryContract`** — `deffetch` declarations for batchable
  fetch operations. Each `deffetch` signals the FiberPool scheduler
  to hold the request — the scheduler collects them across concurrent
  fibers and dispatches to your executor in batched round-trips.
- **`Skuld.Query.Contract`** — protocol for wiring executors to
  contracts. Maps a contract module to its executor at runtime.
- **`Skuld.Query.Cache`** — memoises computation results by key,
  eliminating duplicate work within a batch. Haxl's `memoCache`
  equivalent.

## Why this matters

Without query batching, a typical dashboard that loads users, orders,
and details makes N+1 API calls — one per entity, with no concurrency.
With `defquery`, independent fetches run concurrently, and `deffetch`
calls across fibers are batched into single round-trips to your backend:

```elixir
# Naive: 1 + N + M calls, sequential
def get_dashboard(user_ids) do
  users = Enum.map(user_ids, &fetch_user/1)        # N calls
  details = Enum.map(users, &fetch_details/1)       # M calls
  {users, details}
end

# Skuld: concurrent + batched, 2 round-trips max
defmodule DashboardQueries do
  use Skuld.QueryContract
  deffetch get_user(id :: String.t()) :: User.t()
  deffetch get_order_details(user :: User.t()) :: Details.t()
end

defquery build_dashboard(user_ids) do
  users <- Query.map(user_ids, &DashboardQueries.get_user/1)
  details <- Query.map(users, &DashboardQueries.get_order_details/1)
  {users, details}
end
```

`get_user` calls across all users run concurrently and are batched into
one round-trip at the executor. Same for `get_order_details`. The
dependency graph ensures `get_order_details` waits for `users` to
resolve before executing.

## Installation

```elixir
def deps do
  [
    {:skuld_query, "~> 0.32"}
  ]
end
```

## Further reading

- [Query System](https://hexdocs.pm/skuld_query/query.html) — do-notation and dependency analysis
- [Batch Loading recipe](https://hexdocs.pm/skuld/batch-loading.html) — full N+1 elimination walkthrough
- [QueryContract](https://hexdocs.pm/skuld_query/QueryContract.html) — `deffetch` contracts and executor wiring

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[Query System >](docs/effects/query.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
