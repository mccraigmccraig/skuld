# Channel & Brook

<!-- nav:header:start -->
[< FiberPool](fiberpool.md) | [Up: Coroutines & Concurrency](coroutine.md) | [Index](../../README.md) | [AsyncCoroutine >](async-coroutine.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Channel provides backpressure-aware communication between fibers.
Brook is an effectful streaming layer built on Channel.

Both require FiberPool above them in the handler stack.

## Channel

Bounded and rendezvous (capacity 0) channels for fiber communication:

```elixir
chan <- Channel.new(10)            # bounded channel, capacity 10
_ <- Channel.put(chan, item)       # suspends if full
item <- Channel.take(chan)         # suspends if empty
Channel.close(chan)                # signal no more items

# Async variants (no suspension):
Channel.put_async(chan, item)
{:ok, item} <- Channel.take_async(chan)
```

Rendezvous channels (capacity 0) force put and take to meet:

```elixir
chan <- Channel.new(0)
# Put suspends until a taker arrives; take suspends until a putter arrives
```

Handler:

```elixir
computation |> Channel.with_handler()  # requires FiberPool above it
```

## Brook

Stream processing with effectful operations:

```elixir
stream = Brook.from_enum([1, 2, 3, 4, 5])

result =
  stream
  |> Brook.map(fn x -> x * 2 end)               # per-item effectful transform
  |> Brook.filter(fn x -> x > 5 end)             # effectful filter
  |> Brook.each(fn x -> Writer.tell(:audit, x) end)  # side effects per item
  |> Brook.to_list()                              # collect results
```

Concurrency control via `:concurrency`:

```elixir
stream
|> Brook.map(fn x -> slow_api_call(x) end, concurrency: 4)
|> Brook.to_list()
```

`Brook.reduce/3` threads an accumulator through a stream:

```elixir
total <- Brook.reduce(stream, 0, fn item, acc ->
  price <- PriceService.lookup(item.sku)
  {:ok, acc + price}
end)
```

Brook is a pure combinator — no handler needed. It uses Channel +
FiberPool internally. Install FiberPool and Channel handlers above it:

```elixir
comp do
  result <- Brook.from_enum(items) |> Brook.map(&process/1, concurrency: 4) |> Brook.to_list()
  result
end
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

| Operation | Purpose |
|-----------|---------|
| `Channel.new(cap)` | Create channel (0 = rendezvous) |
| `Channel.put/2`, `take/1` | Blocking send/receive |
| `Channel.put_async/2`, `take_async/1` | Non-blocking send/receive |
| `Brook.from_enum/1` | Create stream from enumerable |
| `Brook.from_function/1` | Create stream from generator |
| `Brook.map/2,3` | Effectful transform (concurrent) |
| `Brook.filter/2,3` | Effectful filter |
| `Brook.each/2` | Side effects per item |
| `Brook.reduce/3` | Effectful reduction |
| `Brook.to_list/1` | Collect stream into list |

<!-- nav:footer:start -->

---

[< FiberPool](fiberpool.md) | [Up: Coroutines & Concurrency](coroutine.md) | [Index](../../README.md) | [AsyncCoroutine >](async-coroutine.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
