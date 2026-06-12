# skuld_port

<!-- nav:header:start -->
[Port >](docs/effects/port.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Port/adapter boundaries for Skuld — typed contracts, pluggable backends,
and bridges between effectful and plain Elixir code. This is the
hexagonal architecture layer: define interfaces, swap implementations.

## What's included

- **`Skuld.Effects.Port`** — dispatches function calls to pluggable
  backends via a registry. Supports plain resolvers (`:direct`, function
  handlers) and effectful resolvers (computation-returning modules with
  compile-time auto-detection via `__port_effectful__?/0`). Merges
  nested registries, supports dispatch logging.
- **`Skuld.Effects.Port.EffectfulFacade`** — generates typed effectful
  callers from `defcallback` declarations. Single-module pattern for
  purely effectful boundaries; three-module pattern for mixed
  Plain/Effectful systems.
- **`Skuld.Adapter`** — bridges an effectful implementation (one whose
  functions return `computation()`) to a plain Elixir interface. Takes
  a contract, an impl module, and a handler stack — generates a module
  that satisfies the plain behaviour.
- **`Skuld.Adapter.EffectfulContract`** — generates effectful `@callback`
  declarations from a DoubleDown contract. The contract module doubles
  as a `__using__` helper so implementations get `@behaviour` and the
  `__port_effectful__?/0` marker in one line.

## The four directions

| Caller | Implementation | Mechanism |
|--------|---------------|-----------|
| Plain Elixir | Plain Elixir | `DoubleDown.ContractFacade` |
| Plain Elixir | Effectful | `Skuld.Adapter` |
| Effectful | Plain Elixir | `Port.with_handler` + `:direct` |
| Effectful | Effectful | `Port.with_handler` + effectful module (auto-detected) |

## Installation

```elixir
def deps do
  [
    {:skuld_port, "~> 0.32"}
  ]
end
```

## Example: single-module effectful boundary

```elixir
# Contract + Facade in one module
defmodule MyApp.Payments do
  use Skuld.Effects.Port.EffectfulFacade
  defcallback charge(amount :: integer()) :: {:ok, receipt()} | {:error, term()}
end

# Implementation — one-liner with compile-time behaviour
defmodule MyApp.Payments.Stripe do
  use Skuld.Syntax
  use MyApp.Payments

  @impl MyApp.Payments
  defcomp charge(amount) do
    {:ok, _} <- StripeAPI.create_charge(amount)
    charge_id <- Fresh.uuid4()
    {:ok, %{charge_id: charge_id}}
  end
end

# Wire at runtime — auto-detected as effectful
MyApp.Payments.charge(99)
|> Port.with_handler(%{MyApp.Payments => MyApp.Payments.Stripe})
|> Throw.with_handler()
|> Comp.run!()
```

## Further reading

- [Port](https://hexdocs.pm/skuld_port/port.html) — resolvers, logging, key-based stubs
- [EffectfulFacade](https://hexdocs.pm/skuld_port/effectful-facade.html) — single-module and three-module patterns
- [Adapter](https://hexdocs.pm/skuld_port/adapter.html) — bridging effectful → plain
- [Hexagonal Architecture](https://hexdocs.pm/skuld/hexagonal-architecture.html) — full recipe with testing

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[Port >](docs/effects/port.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
