# Effects: Collection Iteration

## FxList

Effectful list operations:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{FxList, State}

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

> **Note**: For large iteration counts (10,000+), use `Yield`-based coroutines instead
> of `FxList` for better performance. See the FxList module docs for details.

## FxFasterList

High-performance variant of FxList using `Enum.reduce_while`:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{FxFasterList, State}

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

> **Note**: FxFasterList is ~2x faster than FxList but has limited Yield/Suspend support.
> Use it when performance is critical and you only use Throw for error handling.
