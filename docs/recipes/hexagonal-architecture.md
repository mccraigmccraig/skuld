# Hexagonal Architecture

<!-- nav:header:start -->
[< Testing Effectful Code](testing.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [The Decider Pattern >](decider-pattern.md)
<!-- nav:header:end -->

Hexagonal architecture (ports and adapters) separates domain logic from
infrastructure by defining ports — interfaces through which components
communicate. Skuld's Port system supports incremental adoption: you can
impose port boundaries on existing code without introducing Skuld, then
gradually convert components to effectful implementations at your own pace.

## The four scenarios

A port contract defines an interface. On each side of the interface, the
code can be either **plain Elixir** (legacy/non-effectful) or **effectful**
(Skuld computations). This gives four scenarios:

| # | Caller       | Implementation | Mechanism                                          |
|---|--------------|----------------|----------------------------------------------------|
| 1 | Plain Elixir | Plain Elixir   | `Port.Adapter.Direct`                              |
| 2 | Plain Elixir | Effectful      | `Port.Adapter.Effectful`                           |
| 3 | Effectful    | Plain Elixir   | `Port.with_handler` + `:direct` resolver           |
| 4 | Effectful    | Effectful      | `Port.with_handler` + effectful module (auto-detected) |

The contract generates two behaviours to match:

- `MyContract.Plain` — callbacks return plain values
- `MyContract.Effectful` — callbacks return `computation(return_type)`

## Defining a contract

```elixir
defmodule MyApp.Orders do
  use Skuld.Effects.Port.Contract

  defport place_order(params :: map()) ::
            {:ok, Order.t()} | {:error, term()}

  defport get_order(id :: String.t()) ::
            {:ok, Order.t()} | {:error, term()}
end
```

This generates `MyApp.Orders.Plain` and `MyApp.Orders.Effectful`
behaviours, caller functions, bang variants, and key helpers.

## Incremental adoption walkthrough

Consider a system with three plain Elixir modules forming a dependency
chain:

```
OrderController → OrderService → InventoryService
```

Each calls the next directly. We want to incrementally impose port
boundaries and then convert to Skuld — without a big-bang rewrite.

### Step 1: Define contracts

Define port contracts for the boundaries you want to impose:

```elixir
defmodule MyApp.Orders do
  use Skuld.Effects.Port.Contract

  defport place_order(params :: map()) ::
            {:ok, Order.t()} | {:error, term()}

  defport get_order(id :: String.t()) ::
            {:ok, Order.t()} | {:error, term()}
end

defmodule MyApp.Inventory do
  use Skuld.Effects.Port.Contract

  defport reserve_stock(sku :: String.t(), qty :: integer()) ::
            {:ok, Reservation.t()} | {:error, term()}

  defport check_stock(sku :: String.t()) ::
            {:ok, integer()} | {:error, term()}
end
```

### Step 2: Wire plain→plain with `Adapter.Direct`

The existing implementations already have the right function signatures.
Declare that they satisfy the `Plain` behaviour and create direct adapters:

```elixir
# Existing implementations — add @behaviour
defmodule MyApp.OrderService do
  @behaviour MyApp.Orders.Plain
  # ... existing code unchanged ...
end

defmodule MyApp.InventoryService do
  @behaviour MyApp.Inventory.Plain
  # ... existing code unchanged ...
end

# Direct adapters — plain delegation through the contract
defmodule MyApp.Orders.Adapter do
  use Skuld.Effects.Port.Adapter.Direct,
    contract: MyApp.Orders,
    impl: MyApp.OrderService
end

defmodule MyApp.Inventory.Adapter do
  use Skuld.Effects.Port.Adapter.Direct,
    contract: MyApp.Inventory,
    impl: MyApp.InventoryService
end
```

Now update callers to go through the adapters:

```
OrderController → MyApp.Orders.Adapter → OrderService
                                              ↓
                               MyApp.Inventory.Adapter → InventoryService
```

Nothing uses Skuld yet. The contracts impose compile-time interface
verification via `@behaviour`, and the adapters are simple delegation.
You can swap implementations (e.g. in-memory for tests) by creating
alternative adapters.

### Step 3: Convert a provider to effectful

Now convert `OrderService` to an effectful implementation. It calls
`Inventory` through a Port effect, and its own effects participate in
the caller's context:

```elixir
defmodule MyApp.OrderService.Effectful do
  use Skuld.Syntax
  @behaviour MyApp.Orders.Effectful

  defcomp place_order(params) do
    reservation <- MyApp.Inventory.reserve_stock!(params.sku, params.qty)
    order = %Order{sku: params.sku, qty: params.qty, reservation: reservation}
    {:ok, order}
  end

  defcomp get_order(id) do
    # ... effectful implementation
  end
end
```

The `OrderController` is still plain Elixir, so it needs an
`Adapter.Effectful` to call the effectful implementation:

```elixir
defmodule MyApp.Orders.Adapter do
  use Skuld.Effects.Port.Adapter.Effectful,
    contract: MyApp.Orders,
    impl: MyApp.OrderService.Effectful,
    stack: fn comp ->
      comp
      |> Port.with_handler(%{MyApp.Inventory => MyApp.InventoryService})
      |> Throw.with_handler()
    end
end
```

The call chain is now:

```
OrderController → MyApp.Orders.Adapter [Effectful]
                       ↓ Comp.run!()
                  OrderService.Effectful
                       ↓ Port effect
                  Port.with_handler(:direct)
                       ↓
                  InventoryService (plain)
```

The controller still calls `MyApp.Orders.Adapter.place_order(params)`
and gets a plain `{:ok, order}` back — it doesn't know Skuld is
involved. The effectful order service calls `Inventory` through a Port
effect, which the adapter's stack resolves to the plain
`InventoryService`.

### Step 4: Convert the caller to effectful

Now convert `OrderController` to effectful code (e.g. a LiveView or
an effectful orchestrator):

```elixir
defmodule MyApp.OrderWorkflow do
  use Skuld.Syntax

  defcomp place_order(params) do
    order <- MyApp.Orders.place_order!(params)
    _ <- EventAccumulator.emit(%OrderPlaced{order_id: order.id})
    {:ok, order}
  end
end
```

Since both caller and provider are now effectful, use the `:effectful`
resolver — the order service's computation is inlined into the
workflow's effect context:

```elixir
MyApp.OrderWorkflow.place_order(params)
|> Port.with_handler(%{
  MyApp.Orders => MyApp.OrderService.Effectful,
  MyApp.Inventory => MyApp.InventoryService
})
|> EventAccumulator.with_handler(output: fn r, events -> {r, events} end)
|> Throw.with_handler()
|> Comp.run!()
```

The call chain is now:

```
OrderWorkflow (effectful)
    ↓ Port effect
Port.with_handler (effectful auto-detected)
    ↓ computation inlined
OrderService.Effectful
    ↓ Port effect
Port.with_handler(:direct)
    ↓
InventoryService (plain)
```

All effects from `OrderService.Effectful` (its Port calls, any State,
Throw, etc.) are handled by the workflow's handler stack. There's a
single `Comp.run!` at the top level — no intermediate adapter needed.

### That's it

Note that `InventoryService` stays plain throughout — and that's
perfectly fine. Not everything needs to be effectful. Thin wrappers
around Ecto queries, HTTP clients, or other infrastructure are often
best left as plain Elixir behind a `Plain` behaviour. The port
boundary gives you the interface contract and implementation
swappability without forcing effectful machinery where it adds no
value.

## The four scenarios in detail

### Scenario 1: Plain → Plain (`Adapter.Direct`)

Both caller and implementation are plain Elixir. The adapter delegates
through the contract boundary.

```elixir
defmodule MyApp.Orders.Adapter do
  use Skuld.Effects.Port.Adapter.Direct,
    contract: MyApp.Orders,
    impl: MyApp.OrderService
end

# Usage — plain call, plain result
MyApp.Orders.Adapter.place_order(params)
```

Use this when imposing a port boundary without introducing Skuld.

### Scenario 2: Plain → Effectful (`Adapter.Effectful`)

The caller is plain Elixir, the implementation is effectful. The adapter
wraps the implementation with a handler stack and `Comp.run!()`.

```elixir
defmodule MyApp.Orders.Adapter do
  use Skuld.Effects.Port.Adapter.Effectful,
    contract: MyApp.Orders,
    impl: MyApp.OrderService.Effectful,
    stack: fn comp ->
      comp
      |> Port.with_handler(%{MyApp.Inventory => MyApp.InventoryService})
      |> Throw.with_handler()
    end
end

# Usage — plain call, plain result
MyApp.Orders.Adapter.place_order(params)
```

Use this when a Phoenix controller, GenServer, or other non-effectful
code needs to call effectful domain logic.

### Scenario 3: Effectful → Plain (`:direct` resolver)

The caller is effectful, the implementation is plain Elixir. The Port
handler calls the plain implementation and passes the result to the
continuation.

```elixir
# In effectful code
order <- MyApp.Orders.place_order!(params)

# Wiring
|> Port.with_handler(%{MyApp.Orders => MyApp.OrderService})
```

Use this when effectful domain logic calls out to plain infrastructure
(database queries, HTTP clients, etc.).

### Scenario 4: Effectful → Effectful (auto-detected effectful resolver)

Both caller and implementation are effectful. The Port handler inlines
the implementation's computation into the caller's effect context.

```elixir
# In effectful code
order <- MyApp.Orders.place_order!(params)

# Wiring — implementation's effects handled by this stack
|> Port.with_handler(%{MyApp.Orders => MyApp.OrderService.Effectful})
|> Throw.with_handler()
```

Use this when both sides are effectful and should share the same
effect context (transactions, state, etc.). Modules that `use
MyContract.Effectful` are auto-detected — no `{:effectful, mod}`
wrapper needed.

## Testing

Each scenario has a natural testing approach:

```elixir
# Test with map-based stubs (any scenario)
comp
|> Port.with_test_handler(%{
  MyApp.Orders.key(:place_order, params) => {:ok, %Order{}}
})
|> Throw.with_handler()
|> Comp.run!()

# Test with function-based handler (pattern matching)
comp
|> Port.with_fn_handler(fn
  MyApp.Orders, :place_order, [params] -> {:ok, %Order{}}
  MyApp.Inventory, :reserve_stock, [_sku, _qty] -> {:ok, %Reservation{}}
end)
|> Throw.with_handler()
|> Comp.run!()

# Mixed modes — runtime handler for one contract, test stubs for another
comp
|> Port.with_test_handler(%{
  MyApp.Inventory.key(:reserve_stock, sku, qty) => {:ok, %Reservation{}}
})
|> Port.with_handler(%{MyApp.Orders => MyApp.OrderService.Effectful})
|> Throw.with_handler()
|> Comp.run!()

# Test Adapter.Direct — plain Elixir, no effect machinery
assert {:ok, %Order{}} = MyApp.Orders.Adapter.place_order(params)

# Test Adapter.Effectful — also plain Elixir (adapter runs effects internally)
assert {:ok, %Order{}} = MyApp.Orders.Adapter.place_order(params)
```

### Testing plain hexagons with Mox

For plain hexagons that drive a Port contract (scenarios 1 and 2), you
can use [Mox](https://hexdocs.pm/mox) against the contract's generated
`Plain` behaviour for isolated unit tests — no effect machinery needed.

#### Setup

1. Add Mox to your test dependencies
2. Define a mock in `test/support/mocks.ex`:

```elixir
# test/support/mocks.ex
Mox.defmock(MyApp.Repository.Mock, for: MyApp.Repository.Plain)
```

3. Configure the mock for the test environment:

```elixir
# config/test.exs
config :my_app, :repository, MyApp.Repository.Mock
```

```elixir
# config/config.exs (or config/prod.exs, config/dev.exs)
config :my_app, :repository, MyApp.Repository.Adapter
```

#### Using the mock in tests

Your plain hexagon reads the repository module from application
config at runtime:

```elixir
defmodule MyApp.OrderService do
  defp repo, do: Application.fetch_env!(:my_app, :repository)

  def place_order(params) do
    item = repo().get!(Item, params.item_id)
    changeset = Order.changeset(%Order{}, %{item_id: item.id, qty: params.qty})
    repo().insert(changeset)
  end
end
```

Test with Mox expectations — each test process gets its own
expectations, so `async: true` works:

```elixir
import Mox

setup :verify_on_exit!

test "place_order inserts an order for the item" do
  item = %Item{id: "item-1", name: "Widget"}

  MyApp.Repository.Mock
  |> expect(:get!, fn Item, "item-1" -> item end)
  |> expect(:insert, fn changeset ->
    assert changeset.changes.item_id == "item-1"
    {:ok, Ecto.Changeset.apply_changes(changeset)}
  end)

  assert {:ok, %Order{item_id: "item-1"}} =
    MyApp.OrderService.place_order(%{item_id: "item-1", qty: 3})
end
```

#### Why this works well

- **Async-safe** — Mox expectations are per-process by default
- **No effects needed** — test isolation without introducing Skuld
  computations
- **Incremental** — add a Port contract and get better tests
  immediately, convert to effectful implementations later if desired
- **Familiar** — Mox is a well-known pattern in the Elixir ecosystem

#### Adoption path

1. **Define a Port contract** — `use Skuld.Effects.Port.Contract` with
   `defport` declarations
2. **Implement with `Port.Adapter.Direct`** — wrap your existing module
   to satisfy the Plain behaviour
3. **Use Mox in tests** — `Mox.defmock(Mock, for: MyContract.Plain)`
   for isolated unit tests
4. **Later, optionally** — introduce effectful implementations behind
   the port and use effect-based testing patterns from the
   [Testing Effectful Code](testing.md) recipe

Each step delivers value independently. You don't need to adopt the
full effect system to benefit from Port contracts and test isolation.

## Tips

- Define one contract per bounded context or aggregate
- Keep Plain implementations thin — just infrastructure calls
- The in-memory Plain implementation is your test double — no mocks needed
- Start with `Adapter.Direct` to impose boundaries, convert later
- `use MyContract.Effectful` auto-detects effectful resolvers — no
  `{:effectful, mod}` wrapper needed (though it still works)
- Use `Adapter.Effectful` when you want encapsulated effect execution
- Include `Throw.with_handler/1` in any stack where computations can
  throw — without it, `Comp.run!/1` raises `ThrowError`
- Nested `with_handler`, `with_test_handler`, and `with_fn_handler`
  calls merge into a unified registry — you can mix runtime dispatch
  for some contracts with test stubs for others in the same stack
- For generic Ecto Repo operations (insert, update, delete, get, etc.),
  use the built-in `Port.Repo` contract instead of redeclaring them in
  every domain contract. See
  [Persistence & Data](../effects/persistence.md#portrepo)

<!-- nav:footer:start -->

---

[< Testing Effectful Code](testing.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [The Decider Pattern >](decider-pattern.md)
<!-- nav:footer:end -->
