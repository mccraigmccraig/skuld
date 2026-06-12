# Hexagonal Architecture

<!-- nav:header:start -->
[< Adapter](../../../../docs/effects/adapter.md) | [Index](../../../../README.md) | [Property-Based Testing >](property-testing.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Hexagonal architecture (ports and adapters) separates domain logic from
infrastructure by defining ports — interfaces through which components
communicate. Skuld's Port system supports incremental adoption: define
DoubleDown contracts, then convert components to effectful implementations
at your own pace.

## The four scenarios

| # | Caller | Implementation | Mechanism |
|---|--------|---------------|-----------|
| 1 | Plain Elixir | Plain Elixir | `DoubleDown.ContractFacade` — config-based dispatch |
| 2 | Plain Elixir | Effectful | `Skuld.Adapter` — wraps effectful impl with stack |
| 3 | Effectful | Plain Elixir | `Port.with_handler` + `:direct` resolver |
| 4 | Effectful | Effectful | `Port.with_handler` + effectful module, auto-detected via `__port_effectful__?/0` |

## Setting up a port

Define a contract with `defcallback`:

```elixir
defmodule MyApp.Orders do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback place_order(cart :: Cart.t()) :: {:ok, Order.t()} | {:error, term()}
  defcallback get_order(id :: String.t()) :: {:ok, Order.t()} | {:error, term()}
end
```

This generates effectful callers (returning `computation()`) and
`__key__` helpers for test stubs — all in one module.

## Consumer side (effectful caller)

Write domain logic using the effectful facade:

```elixir
defcomp checkout(cart) do
  {:ok, order} <- MyApp.Orders.place_order(cart)
  order
end
```

Wire the implementation at runtime:

```elixir
checkout(cart)
|> Port.with_handler(%{MyApp.Orders => MyApp.Orders.Ecto})
|> Throw.with_handler()
|> Comp.run!()
```

## Provider side (adapter)

To implement the contract in an effectful style:

```elixir
defmodule MyApp.Effectful.OrderService do
  use Skuld.Syntax
  use MyApp.Orders

  defcomp place_order(cart) do
    inventory <- MyApp.Inventory.check(cart)
    {:ok, order} <- MyApp.OrderRepo.insert(cart, inventory)
    {:ok, order}
  end
end
```

`use MyApp.Orders` generates `@behaviour` and `__port_effectful__?/0` — one
line to declare the implementation and enable Port auto-detection.

And bridge it to plain callers with `Skuld.Adapter`:

```elixir
defmodule MyApp.OrdersAdapter do
  use Skuld.Adapter,
    contract: MyApp.Orders,
    impl: MyApp.Effectful.OrderService,
    stack: fn comp ->
      comp
      |> Port.with_handler(%{MyApp.Inventory => MyApp.InventoryService})
      |> Port.with_handler(%{MyApp.OrderRepo => MyApp.OrderRepo.Ecto})
      |> Throw.with_handler()
    end
end
```

## Internal effectful boundaries

In a purely effectful system, you can decompose a large computation into cells
with typed boundaries. Each cell is a swappable effectful implementation behind
a contract — no Plain code involved. This is hexagonal architecture applied
within the effectful world.

The single-module `EffectfulFacade` is the simplest pattern:

```elixir
# Contract + Facade in one module
defmodule MyApp.Payments do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback charge(amount :: integer()) :: {:ok, receipt()} | {:error, term()}
  defcallback refund(charge_id :: String.t()) :: :ok | {:error, term()}
end

# Implementation — one-liner with compile-time behaviour
defmodule MyApp.Payments.StripeImpl do
  use Skuld.Syntax
  use MyApp.Payments

  def charge(amount) do
    comp do
      {:ok, _} <- StripeAPI.create_charge(amount)
      {:ok, %{charge_id: Ecto.UUID.generate()}}
    end
  end

  def refund(charge_id) do
    comp do
      :ok <- StripeAPI.refund(charge_id)
      :ok
    end
  end
end

# Wire at the boundary — auto-detected as effectful via __port_effectful__?/0
comp do
  {:ok, receipt} <- MyApp.Payments.charge(99)
  receipt
end
|> Port.with_handler(%{MyApp.Payments => MyApp.Payments.StripeImpl})
|> Throw.with_handler()
|> Comp.run!()
```

### Why decompose into cells?

- **Boundary-level testing** — swap the entire `Payments` cell with a stub,
  testing the caller's logic against the contract rather than individual
  operational handlers.
- **Staged evolution** — a flat effect system works fine at small scale. As
  the system grows, introducing cell boundaries isolates change and reduces
  handler-stack complexity.
- **Independent development** — each cell can be built, tested, and swapped
  independently, with the contract as a shared spec between teams.

### Three-module pattern for mixed Plain/Effectful boundaries

When Plain callers also need to hit the same boundary (e.g. LiveView
controllers, tests, or legacy modules), use the three-module pattern:

```elixir
# Plain contract (DoubleDown)
defmodule MyApp.Payments.Contract do
  use DoubleDown.Contract
  defcallback charge(amount :: integer()) :: {:ok, receipt()} | {:error, term()}
end

# Effectful contract (generates callbacks + __using__)
defmodule MyApp.Payments.Effectful do
  use Skuld.Adapter.EffectfulContract,
    double_down_contract: MyApp.Payments.Contract
end

# Facade for effectful callers
defmodule MyApp.Payments do
  use Skuld.Effects.Port.EffectfulFacade,
    contract: MyApp.Payments.Effectful
end

# Adapter for plain callers
defmodule MyApp.Payments.Adapter do
  use Skuld.Adapter,
    contract: MyApp.Payments.Contract,
    impl: MyApp.Payments.EffectfulImpl,
    stack: fn comp -> comp |> Port.with_handler(...) |> Throw.with_handler() end
end
```

The three-module pattern is more ceremony but provides the full hexagon —
both effectful and plain callers use the same underlying contract.

## Testing

Test stubs via the facade's `__key__` helpers:

```elixir
responses = %{
  MyApp.Orders.__key__(:place_order, cart) => {:ok, %Order{id: "123"}}
}

checkout(cart)
|> Port.with_test_handler(responses)
|> Throw.with_handler()
|> Comp.run!()
```

## Incremental adoption

You don't need to convert everything at once. A contract can have
a plain Ecto implementation on one side and effectful code on the other.
New components can be effectful from day one; existing modules can be
adapted gradually through `Skuld.Adapter`.

<!-- nav:footer:start -->

---

[< Adapter](../../../../docs/effects/adapter.md) | [Index](../../../../README.md) | [Property-Based Testing >](property-testing.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
