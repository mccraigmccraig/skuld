# Cooperative Fibers & Concurrency

FiberPool, Channel, and Brook provide cooperative fiber-based concurrency
within a single BEAM process. They enable patterns that are difficult or
impossible with standard BEAM concurrency: automatic I/O batching across
concurrent computations, bounded streaming with backpressure, and
order-preserving concurrent transforms.

> **Note:** The foundational [Parallel](../effects/concurrency.md) effect
> covers common fork-join patterns using BEAM processes. Fibers are for
> when you need fine-grained cooperation, shared effect context, or
> automatic batching.

## Why fibers?

BEAM processes are excellent at isolation, fault tolerance, and
preemptive scheduling. But some patterns work against their strengths:

**Batching I/O across concurrent work.** If 50 BEAM processes each need
to fetch a user from the database, you get 50 queries. There's no
built-in mechanism for processes to discover they're all making the same
kind of request and batch them together. With fibers, the scheduler
sees all suspended fibers, groups their pending requests, and executes
one batched query.

**Shared effect context.** BEAM processes don't share memory. If
concurrent computations need to participate in the same State, Writer,
or transaction context, you need explicit message passing or a shared
process (Agent/ETS). Fibers run in the same process and naturally share
handler scope.

**Order-preserving concurrent transforms.** Processing items
concurrently with BEAM tasks and reassembling results in order requires
manual bookkeeping. Fibers with Channel's `put_async`/`take_async`
preserve order automatically.

**Cost.** Spawning a BEAM process has ~50ms startup overhead for the
full OTP machinery. Fibers are lightweight function calls with minimal
overhead, making them practical for fine-grained concurrency (thousands
of fibers per request).

Fibers are not a replacement for BEAM processes. They're a
complementary concurrency primitive for cooperative patterns within a
computation. For CPU-bound parallelism across cores, use Parallel or
BEAM processes directly.

## FiberPool

Cooperative fibers with automatic I/O batching. FiberPool is the
foundation that Channel, Brook, and the Query system build on.

### Basic usage

```elixir
comp do
  h1 <- FiberPool.fiber(comp do :result_1 end)
  h2 <- FiberPool.fiber(comp do :result_2 end)
  r1 <- FiberPool.await(h1)
  r2 <- FiberPool.await(h2)
  {r1, r2}
end
|> FiberPool.with_handler()
|> Comp.run!()
#=> {:result_1, :result_2}
```

`fiber/1` spawns a computation as a fiber. `await/1` suspends the
current fiber until the target fiber completes.

### Mapping over collections

```elixir
FiberPool.map([1, 2, 3], fn id ->
  comp do %{id: id, name: "User #{id}"} end
end)
|> FiberPool.with_handler()
|> Comp.run!()
#=> [%{id: 1, name: "User 1"}, %{id: 2, ...}, %{id: 3, ...}]
```

`FiberPool.map/2` spawns each computation as a fiber and awaits all
results in order.

### Awaiting multiple fibers

```elixir
comp do
  h1 <- FiberPool.fiber(comp do :first end)
  h2 <- FiberPool.fiber(comp do :second end)
  results <- FiberPool.await_all([h1, h2])
  results
end
|> FiberPool.with_handler()
|> Comp.run!()
#=> [:first, :second]
```

### Parallel tasks

For CPU-bound work that benefits from true parallel execution across
cores, use `task/1` which runs in a separate BEAM process:

```elixir
comp do
  h <- FiberPool.task(fn -> expensive_calculation() end)
  FiberPool.await(h)
end
|> FiberPool.with_handler()
|> Comp.run!()
```

Note: `task/1` takes a thunk (zero-arity function), not a computation.

### Operations

- `fiber(computation)` - spawn a fiber
- `fiber_all(computations)` - spawn multiple fibers
- `spawn_await_all(computations)` - spawn and await all
- `map(list, fun)` - map over items, spawn fibers, await all in order
- `task(thunk)` - run a function in a separate BEAM process
- `await(handle)` - wait for a fiber/task to complete
- `await_all(handles)` - wait for all to complete
- `await_any(handles)` - wait for first to complete
- `cancel(handle)` - cancel a fiber/task

### I/O batching

FiberPool automatically batches I/O operations across suspended fibers.
This is the key mechanism behind automatic query batching - see
[Query & Batching](query-batching.md) for the full story. The short
version: when multiple fibers make the same type of fetch call
concurrently, FiberPool's scheduler groups them and executes a single
batched query.

## Channel

Bounded channels for communication between fibers with backpressure.
Channels provide a way for producer and consumer fibers to communicate
with flow control.

### Basic usage

```elixir
comp do
  ch <- Channel.new(10)  # buffer capacity

  _producer <- FiberPool.fiber(comp do
    _ <- Channel.put(ch, :item1)
    _ <- Channel.put(ch, :item2)
    Channel.close(ch)
  end)

  r1 <- Channel.take(ch)  # {:ok, :item1}
  r2 <- Channel.take(ch)  # {:ok, :item2}
  r3 <- Channel.take(ch)  # :closed

  {r1, r2, r3}
end
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

### Backpressure

- `put/2` suspends when the buffer is full (producer waits)
- `take/1` suspends when the buffer is empty (consumer waits)
- Fibers automatically wake when space/items become available

The buffer capacity controls how far ahead a producer can get. This
prevents fast producers from overwhelming slow consumers.

### Error propagation

```elixir
_ <- Channel.error(ch, :something_failed)
Channel.take(ch)  #=> {:error, :something_failed}
```

Errors flow downstream through channels, allowing consumers to detect
and handle upstream failures.

### Async operations for ordered concurrent processing

`put_async/2` and `take_async/1` enable ordered concurrent
transformations. When you need to transform items concurrently but
preserve their original order:

```elixir
comp do
  ch <- Channel.new(10)  # buffer size = max concurrent transforms

  _producer <- FiberPool.fiber(comp do
    _ <- Channel.put_async(ch, expensive_transform(item1))
    _ <- Channel.put_async(ch, expensive_transform(item2))
    _ <- Channel.put_async(ch, expensive_transform(item3))
    Channel.close(ch)
  end)

  r1 <- Channel.take_async(ch)  # {:ok, transformed1}
  r2 <- Channel.take_async(ch)  # {:ok, transformed2}
  r3 <- Channel.take_async(ch)  # {:ok, transformed3}

  {r1, r2, r3}
end
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

How it works:
- `put_async(ch, computation)` spawns a fiber and stores the handle in
  the buffer (not the result)
- `take_async(ch)` takes the next handle and awaits its completion
- Order is preserved because handles are stored in FIFO order

Buffer size controls concurrency: if capacity is 10, at most 10
transform fibers run in parallel. `put_async` blocks when the buffer
is full, providing natural backpressure.

### Operations

- `new(capacity)` - create a channel
- `put(ch, value)` - send a value (blocks when full)
- `take(ch)` - receive a value (blocks when empty)
- `peek(ch)` - look at the next value without removing
- `close(ch)` - close the channel
- `error(ch, reason)` - send an error downstream
- `put_async(ch, computation)` - spawn a fiber, put handle in buffer
- `take_async(ch)` - take handle, await its result

## Brook

High-level streaming API built on channels. Brook provides composable
stream operations (map, filter, each) with automatic backpressure via
bounded channel buffers.

### Basic usage

```elixir
comp do
  source <- Brook.from_enum(1..100)
  mapped <- Brook.map(source, fn x -> x * 2 end, concurrency: 4)
  filtered <- Brook.filter(mapped, fn x -> rem(x, 4) == 0 end)
  Brook.to_list(filtered)
end
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
#=> [4, 8, 12, 16, ...]
```

### Sources

```elixir
# From an enumerable
source <- Brook.from_enum(items)
source <- Brook.from_enum(items, chunk_size: 50)

# From a producer function
source <- Brook.from_function(fn ->
  case fetch_next_batch() do
    {:ok, items} -> {:items, items}
    :done -> :done
    {:error, e} -> {:error, e}
  end
end)
```

### Operations

- `from_enum(enumerable, opts)` - create a stream from an enumerable
- `from_function(fun, opts)` - create a stream from a producer function
- `map(stream, fun, opts)` - transform items (supports `concurrency:`)
- `filter(stream, fun, opts)` - keep items matching predicate
- `each(stream, fun)` - side-effect for each item
- `run(stream, fun)` - consume the stream
- `to_list(stream)` - collect all items into a list

### Backpressure

Each stream stage uses a bounded channel buffer (default 10). When a
buffer fills, the upstream producer blocks until the consumer catches
up. Configure with the `buffer` option:

```elixir
Brook.map(source, &transform/1, buffer: 20)
```

### I/O batching with Brook

Brook composes with FiberPool's I/O batching for automatic query
optimization. This example fetches users and their orders, with all
queries automatically batched across concurrent fibers:

```elixir
defmodule Queries do
  use Skuld.Query.Contract
  deffetch fetch_user(id :: pos_integer()) :: map() | nil
  deffetch fetch_orders(user_id :: pos_integer()) :: [map()]
end

defcomp user_with_orders(user_id) do
  user <- Queries.fetch_user(user_id)
  orders <- Queries.fetch_orders(user_id)
  %{user | orders: orders}
end

defcomp fetch_all(user_ids) do
  source <- Brook.from_enum(user_ids, chunk_size: 2)
  users <- Brook.map(source, &user_with_orders/1, concurrency: 3)
  Brook.to_list(users)
end

fetch_all([1, 2, 3, 4, 5])
|> Queries.with_executor(QueriesExecutor)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
# 2 batched user fetches + 2 batched order fetches
# instead of 5 + 5 = 10 individual queries
```

Without batching, 5 users with orders would require 10 individual
queries. With batching, fibers running concurrently have their queries
combined into just a handful of executor invocations.

`Brook.map` preserves input order even with `concurrency > 1` by using
`put_async`/`take_async` internally.

### Chunking vs I/O batching

Brook processes items in chunks (default `chunk_size: 100`) for
throughput. Items within a chunk transform sequentially. Setting
`chunk_size: 1` enables true concurrent transforms (and thus I/O
batching per item), at the cost of higher per-item overhead.

For **I/O-heavy workloads** (e.g., 10ms database calls), small chunk
sizes win because batching N queries into 1 dominates the per-item
overhead. For **CPU-bound transforms**, the default chunking is better.

### Comparison with GenStage

| Aspect        | Brook                  | GenStage               |
|---------------|------------------------|------------------------|
| Scheduling    | Cooperative (fibers)   | Preemptive (processes) |
| Communication | Direct (shared memory) | Message passing        |
| Parallelism   | Single process         | Multi-process          |
| Best for      | I/O-bound pipelines    | CPU-bound pipelines    |
| Startup cost  | Minimal                | ~50ms process setup    |
| I/O batching  | Automatic via fibers   | Manual                 |

**When to use each:**

- **Brook** for I/O-bound workloads where automatic batching
  consolidates queries or API calls. Single-process model eliminates
  message-passing overhead.
- **GenStage** for CPU-bound pipelines needing true parallelism across
  cores. Each stage runs in its own process.
- **Hybrid:** Use `FiberPool.task/1` within Brook to offload CPU-heavy
  transforms to separate processes while keeping pipeline coordination
  in Brook.

Brook can be significantly faster for I/O-bound pipelines (up to 300x
for small inputs) due to zero message-passing overhead and chunked
processing. GenStage catches up and wins when stage count exceeds ~15-20
for trivial transforms, because its parallel process execution has
constant overhead regardless of stage count.
