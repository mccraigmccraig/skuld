# Adapter

<!-- nav:header:start -->
[< Port.EffectfulFacade](effectful-facade.md) | [Up: Boundaries](port.md) | [Index](../../README.md) | [Hexagonal Architecture >](../../../skuld/docs/recipes/hexagonal-architecture.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Bridge between effectful and plain Elixir code — both directions.

## Skuld.Adapter

Wraps an effectful implementation as a plain module. Plain code (Phoenix
controllers, GenServers, CLI) calls the adapter's functions like regular
Elixir functions — the adapter runs the effect stack internally:

```elixir
defmodule MyApp.UserService.Adapter do
  use Skuld.Adapter,
    contract: MyApp.UserService,         # DoubleDown contract (plain behaviour)
    impl: MyApp.UserService.EffectfulImpl,  # effectful implementation
    stack: fn comp ->
      comp
      |> Port.with_handler(%{MyApp.Inventory => MyApp.InventoryService})
      |> Throw.with_handler()
    end
end

# Called like a plain function:
MyApp.UserService.Adapter.find_user("123")
# => {:ok, %User{...}}
```

For each `defcallback` in the contract, the adapter generates a function
that calls the effectful impl, pipes through the stack, and runs with
`Comp.run!()`.

## Skuld.Adapter.EffectfulContract

Generates an effectful `@behaviour` from a plain DoubleDown contract:

```elixir
defmodule MyApp.Todos.Contract do
  use DoubleDown.Contract
  defcallback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
end

defmodule MyApp.Todos.Effectful do
  use Skuld.Adapter.EffectfulContract,
    double_down_contract: MyApp.Todos.Contract
end

# Implement:
defmodule MyApp.Todos.EffectfulImpl do
  @behaviour MyApp.Todos.Effectful
  def get_todo(id) do
    {:ok, %Todo{id: id}}
  end
end
```

The generated `@callback` declarations wrap return types in
`computation()`. The module also gets `__port_effectful__?/0` for
auto-detection by the Port system.

## Four directions

| Caller | Implementation | Mechanism |
|--------|---------------|-----------|
| Effectful | Plain | `Port.with_handler` + `:direct` resolver |
| Effectful | Effectful | `Port.with_handler` + effectful module (auto-detected) |
| Plain | Plain | `DoubleDown.ContractFacade` — config-based dispatch |
| Plain | Effectful | `Skuld.Adapter` — wraps effectful impl with stack |

<!-- nav:footer:start -->

---

[< Port.EffectfulFacade](effectful-facade.md) | [Up: Boundaries](port.md) | [Index](../../README.md) | [Hexagonal Architecture >](../../../skuld/docs/recipes/hexagonal-architecture.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
