# Collections

Effectful iteration over lists. When you need to map over a collection
and each iteration uses effects (reading state, writing logs, etc.),
use FxList or FxFasterList.

## FxList

Full-featured effectful map with support for all effects, including
Yield and Suspend:

```elixir
comp do
  results <- FxList.fx_map([1, 2, 3], fn item ->
    comp do
      count <- State.get()
      _ <- State.put(count + 1)
      item * 2
    end
  end)
  results
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {[2, 4, 6], {:final_state, 3}}
```

Each iteration sees the state from previous iterations - the state
threads through sequentially.

> **Note**: For large iteration counts (10,000+), use `Yield`-based
> coroutines instead of `FxList` for better performance. See the FxList
> module docs for details.

## FxFasterList

A ~2x faster variant using `Enum.reduce_while`. The API is identical:

```elixir
comp do
  results <- FxFasterList.fx_map([1, 2, 3], fn item ->
    comp do
      count <- State.get()
      _ <- State.put(count + 1)
      item * 2
    end
  end)
  results
end
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Comp.run!()
#=> {[2, 4, 6], {:final_state, 3}}
```

### When to use which

| | FxList | FxFasterList |
|---|---|---|
| Speed | Baseline | ~2x faster |
| Yield/Suspend | Full support | Limited |
| Throw | Full support | Full support |
| Use when | You need Yield, or list is small | Performance matters, Throw-only errors |
