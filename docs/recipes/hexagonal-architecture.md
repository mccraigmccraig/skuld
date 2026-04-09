# Hexagonal Architecture

<!-- nav:header:start -->
[< Testing Effectful Code](testing.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [The Decider Pattern >](decider-pattern.md)
<!-- nav:header:end -->

Hexagonal architecture (ports and adapters) separates domain logic from
infrastructure by defining ports — interfaces through which components
communicate. Skuld's Port system supports incremental adoption: you can
impose port boundaries on existing code using HexPort's plain dispatch
layer, then gradually convert components to effectful implementations at
your own pace.

## The four scenarios

A port contract defines an interface. On each side of the interface, the
code can be either **plain Elixir** (legacy/non-effectful) or **effectful**
(Skuld computations). This gives four scenarios:

| # | Caller       | Implementation | Mechanism                                          |
|---|--------------|----------------|----------------------------------------------------|
| 1 | Plain Elixir | Plain Elixir   | `HexPort.Facade` — config-dispatched plain calls   |
| 2 | Plain Elixir | Effectful      | `Port.Adapter.Effectful`                           |
| 3 | Effectful    | Plain Elixir   | `Port.with_handler` + `:direct` resolver           |
| 4 | Effectful    | Effectful      | `Port.with_handler` + effectful module (auto-detected) |

A contract module defines `@callback` declarations and
`__port_operations__/0`. The simplest way to set up a port is to combine
the contract and facade in a single module:

- **Plain facade**: `use HexPort.Facade, otp_app: :my_app` — when
  `contract:` is omitted, the module is both contract and facade. Add
  `defport` declarations to define the interface.
- **Effectful facade**: `use Skuld.Effects.Port.Facade, hex_port_contract: MyApp.Orders` —
  when `contract:` is omitted, the module is both effectful contract and
  facade. The effectful callbacks and caller functions are derived from
  the plain contract automatically.

If you need the contract separate from the facade (e.g. a shared library
contract with app-specific facades), pass `contract: MyContract` explicitly.

## Defining a contract

The simplest pattern combines the contract and facade in one module:

```elixir
# Plain contract + facade — defines the port interface and dispatch functions
defmodule MyApp.Orders do
  use HexPort.Facade, otp_app: :my_app

  defport place_order(params :: map()) ::
            {:ok, Order.t()} | {:error, term()}

  defport get_order(id :: String.t()) ::
            {:ok, Order.t()} | {:error, term()}
end

# Effectful contract + facade — derives effectful callbacks and caller functions
defmodule MyApp.Effectful.Orders do
  use Skuld.Effects.Port.Facade,
    hex_port_contract: MyApp.Orders
end
```

`MyApp.Orders` defines `@callback` declarations (the plain behaviour),
generates config-dispatched functions like `MyApp.Orders.place_order/1`,
and provides `__key__/2` helpers for test stubs.

`MyApp.Effectful.Orders` derives effectful `@callback` declarations from
the plain contract and generates effectful caller functions like
`MyApp.Effectful.Orders.place_order/1` (returning computations) and
`MyApp.Effectful.Orders.place_order!/1` (bang variants that dispatch
`Throw` on error).

Both facades alias cleanly — callers use `Orders.place_order(params)` or
`Orders.place_order!(params)` regardless of which facade they import,
making code read the same whether plain or effectful.

## Incremental adoption walkthrough

Consider a system with three plain Elixir modules forming a dependency
chain:

```
OrderController → OrderService → InventoryService
```

Each calls the next directly. We want to incrementally impose port
boundaries and then convert to Skuld — without a big-bang rewrite.

### Step 1: Define contracts

Define port contracts for the boundaries you want to impose. Since we'll
also want plain dispatch, combine the contract and facade in one module:

```elixir
defmodule MyApp.Orders do
  use HexPort.Facade, otp_app: :my_app

  defport place_order(params :: map()) ::
            {:ok, Order.t()} | {:error, term()}

  defport get_order(id :: String.t()) ::
            {:ok, Order.t()} | {:error, term()}
end

defmodule MyApp.Inventory do
  use HexPort.Facade, otp_app: :my_app

  defport reserve_stock(sku :: String.t(), qty :: integer()) ::
            {:ok, Reservation.t()} | {:error, term()}

  defport check_stock(sku :: String.t()) ::
            {:ok, integer()} | {:error, term()}
end
```

### Step 2: Wire plain→plain

The existing implementations already have the right function signatures.
Declare that they satisfy the contract behaviour:

```elixir
# Existing implementations — add @behaviour
defmodule MyApp.OrderService do
  @behaviour MyApp.Orders
  # ... existing code unchanged ...
end

defmodule MyApp.InventoryService do
  @behaviour MyApp.Inventory
  # ... existing code unchanged ...
end
```

Configure the default implementations in your app config:

```elixir
# config/config.exs
config :my_app, MyApp.Orders, impl: MyApp.OrderService
config :my_app, MyApp.Inventory, impl: MyApp.InventoryService
```

Now update callers to go through the facade modules:

```
OrderController → MyApp.Orders → OrderService
                                     ↓
                        MyApp.Inventory → InventoryService
```

Nothing uses Skuld's effect system yet. The contracts impose compile-time
interface verification via `@behaviour`, and the facade modules dispatch
to the configured implementation at runtime. You can swap implementations
(e.g. Mox mocks for tests) via application config or HexPort's test
handler API.

### Step 3: Convert a provider to effectful

Now convert `OrderService` to an effectful implementation. First, define
the effectful facade for the contracts it will call through:

```elixir
defmodule MyApp.Effectful.Inventory do
  use Skuld.Effects.Port.Facade,
    hex_port_contract: MyApp.Inventory
end
```

Then write the effectful implementation. It calls `Inventory` through the
effectful facade, and its own effects participate in the caller's context:

```elixir
defmodule MyApp.Effectful.OrderService do
  use Skuld.Syntax
  alias MyApp.Effectful.Inventory

  @behaviour MyApp.Effectful.Orders

  defcomp place_order(params) do
    reservation <- Inventory.reserve_stock!(params.sku, params.qty)
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
defmodule MyApp.Effectful.OrdersAdapter do
  use Skuld.Effects.Port.Adapter.Effectful,
    contract: MyApp.Orders,
    impl: MyApp.Effectful.OrderService,
    stack: fn comp ->
      comp
      |> Port.with_handler(%{MyApp.Effectful.Inventory => MyApp.InventoryService})
      |> Throw.with_handler()
    end
end
```

The call chain is now:

```
OrderController → MyApp.Effectful.OrdersAdapter [Effectful]
                       ↓ Comp.run!()
                  Effectful.OrderService
                       ↓ Port effect (via Effectful.Inventory)
                  Port.with_handler(:direct)
                       ↓
                  InventoryService (plain)
```

The controller still calls `MyApp.Effectful.OrdersAdapter.place_order(params)`
and gets a plain `{:ok, order}` back — it doesn't know Skuld is
involved. The effectful order service calls `Inventory` through the
effectful facade, which the adapter's stack resolves to the plain
`InventoryService`.

### Step 4: Convert the caller to effectful

Now convert `OrderController` to effectful code (e.g. a LiveView or
an effectful orchestrator). Define the effectful facade for `Orders`:

```elixir
defmodule MyApp.Effectful.Orders do
  use Skuld.Effects.Port.Facade,
    hex_port_contract: MyApp.Orders
end
```

Then write the effectful caller:

```elixir
defmodule MyApp.Effectful.OrderWorkflow do
  use Skuld.Syntax
  alias MyApp.Effectful.Orders

  defcomp place_order(params) do
    order <- Orders.place_order!(params)
    _ <- EventAccumulator.emit(%OrderPlaced{order_id: order.id})
    {:ok, order}
  end
end
```

Since both caller and provider are now effectful, use the `:effectful`
resolver — the order service's computation is inlined into the
workflow's effect context:

```elixir
MyApp.Effectful.OrderWorkflow.place_order(params)
|> Port.with_handler(%{
  MyApp.Effectful.Orders => MyApp.Effectful.OrderService,
  MyApp.Effectful.Inventory => MyApp.InventoryService
})
|> EventAccumulator.with_handler(output: fn r, events -> {r, events} end)
|> Throw.with_handler()
|> Comp.run!()
```

The call chain is now:

```
Effectful.OrderWorkflow (effectful)
    ↓ Port effect
Port.with_handler (effectful auto-detected)
    ↓ computation inlined
Effectful.OrderService
    ↓ Port effect
Port.with_handler(:direct)
    ↓
InventoryService (plain)
```

All effects from `Effectful.OrderService` (its Port calls, any State,
Throw, etc.) are handled by the workflow's handler stack. There's a
single `Comp.run!` at the top level — no intermediate adapter needed.

### That's it

Note that `InventoryService` stays plain throughout — and that's
perfectly fine. Not everything needs to be effectful. Thin wrappers
around Ecto queries, HTTP clients, or other infrastructure are often
best left as plain Elixir behind a contract behaviour. The port boundary
gives you the interface contract and implementation swappability
without forcing effectful machinery where it adds no value.

## The four scenarios in detail

### Scenario 1: Plain → Plain (`HexPort.Facade`)

Both caller and implementation are plain Elixir. The facade module
dispatches to a config-resolved implementation through the contract
boundary.

```elixir
# Combined contract + facade
defmodule MyApp.Orders do
  use HexPort.Facade, otp_app: :my_app

  defport place_order(params :: map()) ::
            {:ok, Order.t()} | {:error, term()}
end

# config/config.exs
config :my_app, MyApp.Orders, impl: MyApp.OrderService

# Usage — plain call, plain result
MyApp.Orders.place_order(params)
```

Use this when imposing a port boundary without introducing Skuld's
effect system. Swap the implementation in `config/test.exs` for Mox
testing, or use HexPort's test handler API.

### Scenario 2: Plain → Effectful (`Adapter.Effectful`)

The caller is plain Elixir, the implementation is effectful. The adapter
wraps the implementation with a handler stack and `Comp.run!()`.

```elixir
defmodule MyApp.Effectful.OrdersAdapter do
  use Skuld.Effects.Port.Adapter.Effectful,
    contract: MyApp.Orders,
    impl: MyApp.Effectful.OrderService,
    stack: fn comp ->
      comp
      |> Port.with_handler(%{MyApp.Effectful.Inventory => MyApp.InventoryService})
      |> Throw.with_handler()
    end
end

# Usage — plain call, plain result
MyApp.Effectful.OrdersAdapter.place_order(params)
```

Use this when a Phoenix controller, GenServer, or other non-effectful
code needs to call effectful domain logic.

### Scenario 3: Effectful → Plain (`:direct` resolver)

The caller is effectful, the implementation is plain Elixir. The Port
handler calls the plain implementation and passes the result to the
continuation.

```elixir
# In effectful code (via effectful facade)
alias MyApp.Effectful.Orders
order <- Orders.place_order!(params)

# Wiring
|> Port.with_handler(%{MyApp.Effectful.Orders => MyApp.OrderService})
```

Use this when effectful domain logic calls out to plain infrastructure
(database queries, HTTP clients, etc.).

### Scenario 4: Effectful → Effectful (auto-detected effectful resolver)

Both caller and implementation are effectful. The Port handler inlines
the implementation's computation into the caller's effect context.

```elixir
# In effectful code (via effectful facade)
alias MyApp.Effectful.Orders
order <- Orders.place_order!(params)

# Wiring — implementation's effects handled by this stack
|> Port.with_handler(%{MyApp.Effectful.Orders => MyApp.Effectful.OrderService})
|> Throw.with_handler()
```

Use this when both sides are effectful and should share the same
effect context (transactions, state, etc.). Modules with a
`__port_effectful__?/0` function are auto-detected as effectful
resolvers — no `{:effectful, mod}` wrapper needed.

## Testing

Each scenario has a natural testing approach:

```elixir
# Test with map-based stubs (any scenario)
comp
|> Port.with_test_handler(%{
  MyApp.Effectful.Orders.__key__(:place_order, params) => {:ok, %Order{}}
})
|> Throw.with_handler()
|> Comp.run!()

# Test with function-based handler (pattern matching)
comp
|> Port.with_fn_handler(fn
  MyApp.Effectful.Orders, :place_order, [params] -> {:ok, %Order{}}
  MyApp.Effectful.Inventory, :reserve_stock, [_sku, _qty] -> {:ok, %Reservation{}}
end)
|> Throw.with_handler()
|> Comp.run!()

# Mixed modes — runtime handler for one contract, test stubs for another
comp
|> Port.with_test_handler(%{
  MyApp.Effectful.Inventory.__key__(:reserve_stock, sku, qty) => {:ok, %Reservation{}}
})
|> Port.with_handler(%{MyApp.Effectful.Orders => MyApp.Effectful.OrderService})
|> Throw.with_handler()
|> Comp.run!()

# Test plain dispatch — plain Elixir, no effect machinery
assert {:ok, %Order{}} = MyApp.Orders.place_order(params)

# Test Adapter.Effectful — also plain Elixir (adapter runs effects internally)
assert {:ok, %Order{}} = MyApp.Effectful.OrdersAdapter.place_order(params)
```

### Testing plain hexagons with Mox

For plain hexagons that drive a Port contract (scenarios 1 and 2), you
can use [Mox](https://hexdocs.pm/mox) against the contract's generated
behaviour for isolated unit tests — no effect machinery needed.

The facade module dispatches to a config-resolved implementation,
so swapping in a Mox mock is just a config change.

#### Setup

1. Add Mox to your test dependencies
2. Define a mock in `test/support/mocks.ex`:

```elixir
# test/support/mocks.ex
Mox.defmock(MyApp.Orders.Mock, for: MyApp.Orders)
```

3. Point the app at the mock in test config:

```elixir
# config/test.exs
config :my_app, MyApp.Orders, impl: MyApp.Orders.Mock
```

Production config points to the real implementation; the test config
overrides it with the mock.

#### Using the mock in tests

Your plain hexagon calls the facade module directly — no config
awareness needed at the call site:

```elixir
defmodule MyApp.OrderService do
  alias MyApp.Repository

  def place_order(params) do
    item = Repository.get!(Item, params.item_id)
    changeset = Order.changeset(%Order{}, %{item_id: item.id, qty: params.qty})
    Repository.insert(changeset)
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

  MyApp.Orders.Mock
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

1. **Define a facade** — `use HexPort.Facade, otp_app: :my_app` with
   `defport` declarations (combined contract + facade)
2. **Use Mox in tests** — `Mox.defmock(Mock, for: MyApp.Orders)`,
   point app at mock via `config/test.exs`
3. **Later, optionally** — define `MyApp.Effectful.Orders` with
   `use Skuld.Effects.Port.Facade` for effectful callers, use
   `Adapter.Effectful` for plain callers of effectful implementations

Each step delivers value independently. You don't need to adopt the
full effect system to benefit from Port contracts and test isolation.

### Testing plain hexagons with HexPort test doubles

HexPort includes its own process-scoped test handler system built on
`NimbleOwnership`. Unlike Mox, no mock modules are defined at compile
time — handlers are registered at runtime per-test via closures or
module references. This gives you three handler modes plus two built-in
Repo test doubles, all compatible with `async: true`.

#### Setup

Start the ownership server once in `test/test_helper.exs`:

```elixir
{:ok, _} = HexPort.Testing.start()
```

#### Three handler modes

**Module handler** — register any module that implements the contract's
`@behaviour`:

```elixir
HexPort.Testing.set_handler(MyApp.Orders, MyApp.FakeOrderService)
```

**Function handler** — register a 2-arity closure
`(operation, args) -> result` with pattern matching:

```elixir
HexPort.Testing.set_fn_handler(MyApp.Orders, fn
  :place_order, [params] -> {:ok, %Order{sku: params.sku}}
  :get_order, ["order-1"] -> {:ok, %Order{id: "order-1"}}
end)
```

**Stateful handler** — register a 3-arity closure
`(operation, args, state) -> {result, new_state}` with an initial
state value. State is stored in NimbleOwnership and updated atomically
on each dispatch:

```elixir
HexPort.Testing.set_stateful_handler(
  MyApp.Inventory,
  fn
    :reserve_stock, [sku, qty], stock ->
      current = Map.get(stock, sku, 0)
      if current >= qty do
        {{:ok, %Reservation{sku: sku, qty: qty}}, Map.update!(stock, sku, &(&1 - qty))}
      else
        {{:error, :insufficient_stock}, stock}
      end

    :check_stock, [sku], stock ->
      {{:ok, Map.get(stock, sku, 0)}, stock}
  end,
  %{"widget" => 100, "gadget" => 50}  # initial state
)
```

#### Process sharing

Child processes (Tasks, Agents) inherit the parent's handlers
automatically via `$callers`. For non-Task processes, use `allow/3`:

```elixir
HexPort.Testing.allow(MyApp.Orders, self(), agent_pid)
```

#### Dispatch logging

Assert on the exact sequence of port calls made during a test:

```elixir
HexPort.Testing.enable_log(MyApp.Orders)

MyApp.OrderService.place_order(%{sku: "widget", qty: 3})

log = HexPort.Testing.get_log(MyApp.Orders)
assert [{MyApp.Orders, :place_order, [%{sku: "widget", qty: 3}], {:ok, _}}] = log
```

#### Cleanup

Call `HexPort.Testing.reset/0` to clear all handlers, state, and logs
for the current process (useful in `setup` blocks).

#### Built-in Repo test doubles

HexPort ships two test doubles for the `Port.Repo` contract:

**`Repo.Test`** — stateless. Writes apply changeset changes and return
`{:ok, struct}` but store nothing. Reads delegate to an optional
fallback function or raise with an actionable suggestion:

```elixir
HexPort.Testing.set_fn_handler(
  HexPort.Repo.Contract,
  HexPort.Repo.Test.new(
    fallback_fn: fn
      :get, [User, 1] -> %User{id: 1, name: "Alice"}
      :all, [User] -> [%User{id: 1}]
    end
  )
)
```

**`Repo.InMemory`** — stateful. Provides read-after-write consistency
for primary-key lookups (`get`, `get!`). State is a nested map
`%{schema_module => %{pk => struct}}` stored in NimbleOwnership and
updated atomically. Writes insert/update/delete records in state;
PK reads check state first, then fall back; non-PK reads (`get_by`,
`all`, `exists?`, etc.) always delegate to a fallback or raise:

```elixir
HexPort.Testing.set_stateful_handler(
  HexPort.Repo.Contract,
  &HexPort.Repo.InMemory.dispatch/3,
  HexPort.Repo.InMemory.new(
    seed: [%User{id: 1, name: "Alice"}, %Item{id: 1, sku: "widget"}],
    fallback_fn: fn
      :all, [Item], state -> Map.values(state[Item] || %{})
    end
  )
)
```

Both test doubles handle `transact` (0-arity fns, 1-arity fns, and
`Ecto.Multi`) via a shared `MultiStepper` that walks through Multi
operations without a real database.

#### Why `Repo.InMemory` matters

The in-memory Repo gives you database-free tests for Ecto-heavy code.
Because there's no database roundtrip, tests run at pure-function speed
— fast enough for property-based testing with StreamData or similar.
You get:

- **No sandbox, no migrations, no DB setup** — tests start instantly
- **Read-after-write consistency** — insert a record then `get` it back
- **Full Ecto.Multi support** — multi-step transactions work correctly
- **Property-based testing speed** — thousands of test cases per second
  because there's no I/O

This is particularly valuable for testing domain logic that interleaves
Ecto operations — the hexagonal boundary lets you swap the real Repo
for `Repo.InMemory` and verify business rules without database overhead.

## Tips

- Define one contract per bounded context or aggregate
- Keep contract implementations thin — just infrastructure calls
- The in-memory implementation is your test double — no mocks needed
- Start with `HexPort.Facade` to impose boundaries, convert later
- Effectful facades (from `use Skuld.Effects.Port.Facade`) have
  `__port_effectful__?/0` and auto-detect as effectful resolvers
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
