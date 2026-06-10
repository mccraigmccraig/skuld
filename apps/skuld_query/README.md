# skuld_query

<!-- nav:header:start -->
[Query System >](docs/effects/query.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Auto-batching data fetches for Skuld: Haxl-style query do-notation with dependency analysis and concurrent dispatch.

## What's included

- **`Skuld.Query`** — `query`/`defquery` do-notation macros
- **`Skuld.QueryContract`** — `deffetch` for batchable fetch contracts
- **`Skuld.Query.Contract`** — query contract protocol and wiring
- **`Skuld.Query.QueryBlock`** — dependency graph analysis and concurrent execution
- **`Skuld.Query.Cache`** — computation memoization

## Installation

```elixir
def deps do
  [
    {:skuld_query, "~> 0.32"}
  ]
end
```

## Quick start

```elixir
defmodule MyApp.Queries do
  use Skuld.QueryContract

  deffetch get_user(id :: String.t()) :: User.t() | nil
  deffetch get_orders(user_id :: String.t()) :: [Order.t()]
end

use Skuld.Query

defquery user_with_orders(id) do
  user <- MyApp.Queries.get_user(id)
  orders <- MyApp.Queries.get_orders(id)
  {user, orders}
end
```

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[Query System >](docs/effects/query.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
