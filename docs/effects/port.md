# Port

<!-- nav:header:start -->
[< EffectLogger & SerializableCoroutine](effectlogger.md) | [Index](../../README.md) | [Port.EffectfulFacade >](effectful-facade.md)
<!-- nav:header:end -->

Port is the dispatch effect for external integration. It routes
`Port.request(mod, name, args)` to pluggable backends — database queries,
HTTP calls, file I/O, or any side-effecting function.

## Operations

```elixir
result <- Port.request(Module, :function, [arg1, arg2])  # raw result tuple
value <- Port.request!(Module, :function, [arg1, arg2])  # unwrap {:ok, v} or throw
```

`request/3` returns `{:ok, value}` or `{:error, reason}` as-is.
`request!/3` unwraps `:ok` or dispatches `Throw.throw(reason)` on error.

## Handler — production

Map contract modules to resolvers:

```elixir
computation
|> Port.with_handler(%{
  MyApp.UserQueries => :direct,              # call module directly
  MyApp.PaymentAPI => MyApp.PaymentAPI.HTTP, # dispatch to impl module
  MyApp.Repo.Contract => MyApp.Repo.Ecto,    # module-based resolver
})
|> Throw.with_handler()   # for request!/3 error unwrapping
|> Comp.run!()
```

### Resolver types

| Resolver | Behavior |
|----------|----------|
| `:direct` | `apply(mod, name, args)` |
| `module` | `apply(module, name, args)`. If `__port_effectful__?/0` returns true, treated as `:effectful` |
| `{:effectful, module}` | Returns a computation, inlined into current context |
| `fn mod, name, args -> ... end` | Function-based resolver |
| `{mod, fun}` | `apply(mod, fun, [mod, name, args])` |

## Handler — test

Map-based stubs with exact key matching:

```elixir
responses = %{
  Port.key(MyApp.Users, :find_by_id, [123]) => {:ok, %{name: "Alice"}},
  Port.key(MyApp.Users, :find_by_id, [456]) => {:error, :not_found}
}

computation |> Port.with_test_handler(responses) |> Throw.with_handler() |> Comp.run!()
```

Function-based stubs with full pattern matching:

```elixir
handler = fn
  MyApp.Users, :find_by_id, [id] when id < 100 -> {:ok, %{id: id}}
  MyApp.Users, :find_by_id, [_] -> {:error, :not_found}
  MyApp.Audit, _name, _args -> :ok
end

computation |> Port.with_fn_handler(handler) |> Throw.with_handler() |> Comp.run!()
```

Stateful handler for read-after-write consistency:

```elixir
handler = fn
  MyRepo, :insert, [record], state ->
    {{:ok, record}, Map.put(state, record.id, record)}
  MyRepo, :get, [id], state ->
    {Map.get(state, id), state}
end

computation |> Port.with_stateful_handler(%{}, handler) |> Throw.with_handler() |> Comp.run!()
```

## Dispatch logging

Enable `:log` to record every dispatch as `{mod, name, args, result}`:

```elixir
{result, log} =
  computation
  |> Port.with_handler(registry, log: true, output: fn result, state ->
    {result, state.log}
  end)
  |> Comp.run!()
```

## Nested handlers

Nested `with_handler` calls merge registries — inner entries win on
conflict. When the inner scope exits, the previous registry is restored.

<!-- nav:footer:start -->

---

[< EffectLogger & SerializableCoroutine](effectlogger.md) | [Index](../../README.md) | [Port.EffectfulFacade >](effectful-facade.md)
<!-- nav:footer:end -->
