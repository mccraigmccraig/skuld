# Port.EffectfulFacade

Generates typed effectful caller functions from `defcallback` declarations.
The callers return `computation(return_type)` values that dispatch via the
Port effect.

## Single-module (simplest)

Define callbacks directly in the facade module:

```elixir
defmodule MyApp.Todos do
  use Skuld.Effects.Port.EffectfulFacade

  defcallback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
  defcallback list_todos() :: [Todo.t()]
end
```

`MyApp.Todos` now has effectful `@callback`s, `__callbacks__/0`,
`__port_effectful__?/0`, and dispatch functions:

```elixir
comp do
  todo <- MyApp.Todos.get_todo("42")    # returns computation
  todo
end
|> Port.with_handler(%{MyApp.Todos => MyApp.Todos.Ecto})
|> Throw.with_handler()
|> Comp.run!()
```

## From a DoubleDown contract

When the contract and facade are separate:

```elixir
defmodule MyApp.Todos.Contract do
  use DoubleDown.Contract
  defcallback get_todo(id :: String.t()) :: {:ok, Todo.t()} | {:error, term()}
end

defmodule MyApp.Todos do
  use Skuld.Effects.Port.EffectfulFacade,
    double_down_contract: MyApp.Todos.Contract
end
```

## Test stub keys

The `__key__` helpers generate canonical keys for `Port.with_test_handler`:

```elixir
responses = %{
  MyApp.Todos.__key__(:get_todo, "42") => {:ok, %Todo{id: "42"}}
}

computation |> Port.with_test_handler(responses) |> Comp.run!()
```

| Option | Purpose |
|--------|---------|
| (none) | Single-module: callbacks + facade in one module |
| `:double_down_contract` | Combine effectful contract + facade from a DD contract |
| `:contract` | Separate effectful contract module (used with Adapter.EffectfulContract) |

## Handler wiring

Register the facade module as an effectful resolver:

```elixir
Port.with_handler(%{MyApp.Todos => MyApp.Todos.Ecto})
```

If the implementation's functions return computations (via
`__port_effectful__?/0`), Port auto-detects and inlines them into the
current effect context.
