# skuld_port

<!-- nav:header:start -->
[Port >](docs/effects/port.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Port/adapter boundaries for Skuld: dispatch to pluggable backends, typed contracts, and bridge adapters.

## What's included

- **`Skuld.Effects.Port`** — parameterized dispatch to pluggable backends
- **`Skuld.Effects.Port.EffectfulFacade`** — typed effectful contracts via `defcallback`
- **`Skuld.Adapter`** — bridges effectful implementations to plain Elixir interfaces
- **`Skuld.Adapter.EffectfulContract`** — plain behaviour contracts for adapters
- **`Skuld.Effects.Command`** — unified command dispatch pipeline
- **`Skuld.Effects.Transaction`** — env state rollback with optional database transactions

## Installation

```elixir
def deps do
  [
    {:skuld_port, "~> 0.32"}
  ]
end
```

## Quick start

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Port, Throw}

comp do
  {:ok, user} <- Port.request(MyApp.Users, :get_user, [user_id])
  user
end
|> Port.with_handler(%{MyApp.Users => MyApp.Users.Impl})
|> Throw.with_handler()
|> Comp.run!()
```

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[Port >](docs/effects/port.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
