# FxList

Effectful iteration over collections — each element can trigger effects
within the current handler context.

## FxList (general)

Full effect support, including Yield and Suspend:

```elixir
results <- FxList.fx_map(users, fn user ->
  details <- Repo.get(UserDetail, user.id)
  {:ok, %{user | details: details}}
end)

total <- FxList.fx_reduce(items, 0, fn item, acc ->
  price <- PriceService.lookup(item.sku)
  {:ok, acc + price}
end)

_ <- FxList.fx_each(users, fn user ->
  Writer.tell(:audit, {:processed, user.id})
end)

active <- FxList.fx_filter(users, fn user ->
  sub <- Repo.get(Subscription, user.id)
  {:ok, sub.status == :active}
end)
```

## FxFasterList (performance)

Higher throughput (~0.1 µs/op vs ~0.2 µs/op for FxList). Limited Yield
support — best for effectful operations that don't suspend:

```elixir
result <- FxFasterList.fx_map(items, &process/1)
```

| Combinator | FxList | FxFasterList | Yield support |
|-----------|--------|-------------|---------------|
| `fx_map/2` | ✓ | ✓ | Full / Limited |
| `fx_reduce/3` | ✓ | ✓ | Full / Limited |
| `fx_each/2` | ✓ | ✓ | Full / Limited |
| `fx_filter/2` | ✓ | ✓ | Full / Limited |

Both are pure combinators — no handler needed. They iterate through
each element, running the provided effectful function, collecting results.
