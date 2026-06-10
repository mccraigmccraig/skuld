# Hexagonal Architecture

<!-- nav:header:start -->
[< Command & Transaction](../../../../docs/effects/command-transaction.md) | [Index](../../../../README.md) | [Property-Based Testing >](property-testing.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
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
| 4 | Effectful | Effectful | `Port.with_handler` + effectful module (auto-detected) |

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
  @behaviour MyApp.Orders

  defcomp place_order(cart) do
    inventory <- MyApp.Inventory.check(cart)
    {:ok, order} <- MyApp.OrderRepo.insert(cart, inventory)
    {:ok, order}
  end
end
```

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

[< Command & Transaction](../../../../docs/effects/command-transaction.md) | [Index](../../../../README.md) | [Property-Based Testing >](property-testing.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
