# Effects: Concurrency

## AtomicState

Thread-safe state for concurrent contexts. Unlike the regular State effect which
stores state in `env.state` (copied when forking to new processes), AtomicState
uses external storage (Agent) that can be safely accessed from multiple processes:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.AtomicState

# Basic usage - similar to State but with atomic guarantees
comp do
  _ <- AtomicState.put(0)
  _ <- AtomicState.modify(&(&1 + 1))
  AtomicState.get()
end
|> AtomicState.with_agent_handler(0)
|> Comp.run!()
#=> 1

# Compare-and-swap for lock-free coordination
comp do
  _ <- AtomicState.put(10)
  r1 <- AtomicState.cas(10, 20)  # succeeds: current == expected
  r2 <- AtomicState.cas(10, 30)  # fails: current is 20, not 10
  final <- AtomicState.get()
  {r1, r2, final}
end
|> AtomicState.with_agent_handler(0)
|> Comp.run!()
#=> {:ok, {:conflict, 20}, 20}

# Multiple independent states with tags
comp do
  _ <- AtomicState.put(:counter, 0)
  _ <- AtomicState.put(:cache, %{})
  _ <- AtomicState.modify(:counter, &(&1 + 1))
  _ <- AtomicState.modify(:cache, &Map.put(&1, :key, "value"))
  counter <- AtomicState.get(:counter)
  cache <- AtomicState.get(:cache)
  {counter, cache}
end
|> AtomicState.with_agent_handler(0, tag: :counter)
|> AtomicState.with_agent_handler(%{}, tag: :cache)
|> Comp.run!()
#=> {1, %{key: "value"}}

# Testing: State-backed handler (no Agent processes)
comp do
  _ <- AtomicState.modify(&(&1 + 10))
  AtomicState.get()
end
|> AtomicState.with_state_handler(5)
|> Comp.run!()
#=> 15
```

Operations: `get/1`, `put/2`, `modify/2`, `atomic_state/2` (get-and-update), `cas/3`

## Parallel

Simple fork-join concurrency with built-in boundaries. Each operation is self-contained
with automatic task management:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Parallel, Throw}

# Run multiple computations in parallel, get all results
comp do
  Parallel.all([
    comp do %{id: 1, name: "Alice"} end,
    comp do %{id: 2, name: "Bob"} end,
    comp do %{id: 3, name: "Carol"} end
  ])
end
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}, %{id: 3, name: "Carol"}]

# Race: return first to complete, cancel others
comp do
  Parallel.race([
    comp do :slow_result end,
    comp do :fast_result end
  ])
end
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> :slow_result or :fast_result (first to complete wins)

# Map over items in parallel
comp do
  Parallel.map([1, 2, 3], fn id ->
    comp do %{id: id, name: "User #{id}"} end
  end)
end
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [%{id: 1, name: "User 1"}, %{id: 2, name: "User 2"}, %{id: 3, name: "User 3"}]
```

**Error handling**: Task failures are caught. For `all/1` and `map/2`, the first
failure returns `{:error, {:task_failed, reason}}`. For `race/1`, failures are
ignored unless all tasks fail.

**Testing handler** runs tasks sequentially for deterministic tests:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Parallel, Throw}

comp do
  Parallel.all([comp do :a end, comp do :b end])
end
|> Parallel.with_sequential_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [:a, :b]
```

Operations: `all/1`, `race/1`, `map/2`

## AsyncComputation

Run effectful computations from non-effectful code (e.g., LiveView), bridging yields,
throws, and results back via messages:

```elixir
alias Skuld.AsyncComputation
alias Skuld.Comp.{Suspend, Throw, Cancelled}

# Build a computation with handlers
computation =
  comp do
    name <- Yield.yield(:get_name)
    email <- Yield.yield(:get_email)
    {:ok, %{name: name, email: email}}
  end
  |> Reader.with_handler(%{tenant_id: "t-123"})

# Start async - returns immediately, first response via message
{:ok, runner} = AsyncComputation.start(computation, tag: :create_user)

# Start sync - blocks until first yield/result/throw (for fast-yielding computations)
{:ok, runner, %Suspend{value: :get_name, data: data}} =
  AsyncComputation.start_sync(computation, tag: :create_user, timeout: 5000)
# `data` contains any decorations from scoped effects (e.g., EffectLogger log)

# Messages arrive as {AsyncComputation, tag, result} where result is:
# - %Suspend{value: v, data: d}  <- computation yielded (data has effect decorations)
# - %Throw{error: e}             <- computation threw
# - %Cancelled{reason: r}        <- computation was cancelled
# - plain value                  <- computation completed successfully

# Resume async - returns immediately, next response via message
AsyncComputation.resume(runner, "Alice")

# Resume sync - blocks until next yield/result/throw
case AsyncComputation.resume_sync(runner, "Alice", timeout: 5000) do
  %Suspend{value: next_prompt} -> # computation yielded again
  %Throw{error: error} -> # computation threw
  %Cancelled{reason: reason} -> # computation was cancelled
  value -> # computation completed with value
  {:error, :timeout} -> # timed out
end

# Cancel if needed - triggers proper cleanup via leave_scope
AsyncComputation.cancel(runner)
```

### LiveView Example

```elixir
alias Skuld.AsyncComputation
alias Skuld.Comp.{Suspend, Throw, Cancelled}

def handle_event("start_wizard", _params, socket) do
  computation =
    comp do
      name <- Yield.yield(%{step: 1, prompt: "Enter name"})
      email <- Yield.yield(%{step: 2, prompt: "Enter email"})
      {:ok, %{name: name, email: email}}
    end
    |> MyApp.with_domain_handlers()

  {:ok, runner} = AsyncComputation.start(computation, tag: :wizard)
  {:noreply, assign(socket, runner: runner, step: nil)}
end

# Single clause handles all messages for a tag - easy delegation
def handle_info({AsyncComputation, :wizard, result}, socket) do
  case result do
    %Suspend{value: %{step: step, prompt: prompt}} ->
      {:noreply, assign(socket, step: step, prompt: prompt)}

    %Throw{error: error} ->
      {:noreply, socket |> assign(runner: nil) |> put_flash(:error, inspect(error))}

    %Cancelled{reason: _reason} ->
      {:noreply, assign(socket, runner: nil)}

    {:ok, user} ->
      {:noreply, socket |> assign(user: user, runner: nil) |> put_flash(:info, "Created!")}
  end
end

def handle_event("submit_step", %{"value" => value}, socket) do
  AsyncComputation.resume(socket.assigns.runner, value)
  {:noreply, socket}
end
```

**Key points:**

- Adds `Throw.with_handler/1` and `Yield.with_handler/1` automatically
- Uniform message format `{AsyncComputation, tag, result}` enables single-clause delegation
- Exceptions in computations become `%Throw{error: %{kind: :error, payload: exception}}`
- Cancellation triggers proper cleanup via `leave_scope` chain
- Linked by default (use `link: false` for unlinked)
- `Suspend.data` contains decorations from scoped effects (e.g., `data[EffectLogger]` has the current log)
- Use this for non-effectful callers; use `FiberPool` effect when inside a computation

Operations: `start/2`, `start_sync/2`, `resume/2`, `resume_sync/3`, `cancel/1`

## FiberPool

Cooperative fiber-based concurrency with automatic I/O batching. Fibers are lightweight
computations that yield cooperatively and can be scheduled together for efficient execution.

### Basic usage

```elixir
use Skuld.Syntax
alias Skuld.Effects.FiberPool

comp do
  # Spawn fibers
  h1 <- FiberPool.fiber(comp do :result_1 end)
  h2 <- FiberPool.fiber(comp do :result_2 end)

  # Await results
  r1 <- FiberPool.await(h1)
  r2 <- FiberPool.await(h2)
  {r1, r2}
end
|> FiberPool.with_handler()
|> FiberPool.run!()
#=> {:result_1, :result_2}
```

### Await multiple fibers

```elixir
use Skuld.Syntax
alias Skuld.Effects.FiberPool

comp do
  h1 <- FiberPool.fiber(comp do :first end)
  h2 <- FiberPool.fiber(comp do :second end)

  # Wait for all - results in order
  results <- FiberPool.await_all([h1, h2])
  results
end
|> FiberPool.with_handler()
|> FiberPool.run!()
#=> [:first, :second]
```

### I/O Batching

FiberPool automatically batches I/O operations across suspended fibers:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.FiberPool

# Define a typed query contract
defmodule UserQueries do
  use Skuld.Query.Contract
  defquery get_user(id :: pos_integer()) :: map() | nil
end

# Implement the executor
defmodule UserQueries.Impl do
  @behaviour UserQueries.Executor

  @impl true
  def get_user(ops) do
    IO.puts("Executor called with #{length(ops)} operations")  # proves batching
    Comp.pure(Map.new(ops, fn {ref, %UserQueries.GetUser{id: id}} ->
      {ref, %{id: id, name: "User #{id}"}}
    end))
  end
end

# Multiple fibers fetching users - batched into single executor call
comp do
  h1 <- FiberPool.fiber(UserQueries.get_user(1))
  h2 <- FiberPool.fiber(UserQueries.get_user(2))
  h3 <- FiberPool.fiber(UserQueries.get_user(3))

  results <- FiberPool.await_all([h1, h2, h3])
  results
end
|> UserQueries.with_executor(UserQueries.Impl)
|> FiberPool.with_handler()
|> FiberPool.run!()
# Prints: Executor called with 3 operations
#=> [%{id: 1, name: "User 1"}, %{id: 2, name: "User 2"}, %{id: 3, name: "User 3"}]
```

### Parallel Tasks

For CPU-bound work that benefits from parallel execution:

```elixir
use Skuld.Syntax
alias Skuld.Effects.FiberPool

comp do
  # Task runs in separate process (takes a thunk, not a computation)
  h <- FiberPool.task(fn -> expensive_calculation() end)
  FiberPool.await(h)
end
|> FiberPool.with_handler()
|> FiberPool.run!()
```

Operations: `fiber/1`, `task/1`, `await/1`, `await_all/1`, `await_any/1`, `cancel/1`

## Channel

Bounded channels for communication between fibers with backpressure:

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Channel, FiberPool}

comp do
  ch <- Channel.new(10)  # buffer capacity

  # Producer fiber
  _producer <- FiberPool.fiber(comp do
    _ <- Channel.put(ch, :item1)
    _ <- Channel.put(ch, :item2)
    Channel.close(ch)
  end)

  # Consumer
  r1 <- Channel.take(ch)  # {:ok, :item1}
  r2 <- Channel.take(ch)  # {:ok, :item2}
  r3 <- Channel.take(ch)  # :closed

  {r1, r2, r3}
end
|> Channel.with_handler()
|> FiberPool.with_handler()
|> FiberPool.run!()
```

### Backpressure

- `put/2` suspends when buffer is full
- `take/1` suspends when buffer is empty
- Fibers automatically wake when space/items become available

### Error propagation

```elixir
use Skuld.Syntax
alias Skuld.Effects.Channel

# Errors flow downstream through channels
_ <- Channel.error(ch, :something_failed)
Channel.take(ch)  #=> {:error, :something_failed}
```

Operations: `new/1`, `put/2`, `take/1`, `peek/1`, `close/1`, `error/2`

### Async Operations for Ordered Concurrent Processing

`put_async/2` and `take_async/1` enable ordered concurrent transformations. When
you need to transform items concurrently but preserve their original order:

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Channel, FiberPool}

comp do
  ch <- Channel.new(10)  # buffer size = max concurrent transforms

  # Producer: spawns transform fibers, stores handles in order
  _producer <- FiberPool.fiber(comp do
    _ <- Channel.put_async(ch, expensive_transform(item1))
    _ <- Channel.put_async(ch, expensive_transform(item2))
    _ <- Channel.put_async(ch, expensive_transform(item3))
    Channel.close(ch)
  end)

  # Consumer: awaits results in put-order
  r1 <- Channel.take_async(ch)  # {:ok, transformed1}
  r2 <- Channel.take_async(ch)  # {:ok, transformed2}
  r3 <- Channel.take_async(ch)  # {:ok, transformed3}

  {r1, r2, r3}
end
|> Channel.with_handler()
|> FiberPool.with_handler()
|> FiberPool.run!()
```

**How it works:**
- `put_async(ch, computation)` spawns a fiber for the computation and stores
  the fiber handle in the buffer (not the result)
- `take_async(ch)` takes the next fiber handle and awaits its completion
- Order is preserved because handles are stored in FIFO order, and we await
  them sequentially regardless of which computation finishes first

**Buffer size controls concurrency:** If the buffer capacity is 10, at most 10
transform fibers run in parallel - `put_async` blocks when the buffer is full,
providing natural backpressure.

Operations: `put_async/2`, `take_async/1`

## Brook

High-level streaming API built on channels, with automatic backpressure via
bounded channel buffers - producers block when downstream consumers can't keep up:

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Brook, Channel, FiberPool}

comp do
  # Create stream from enumerable
  source <- Brook.from_enum(1..100)

  # Transform with optional concurrency
  mapped <- Brook.map(source, fn x -> x * 2 end, concurrency: 4)

  # Filter
  filtered <- Brook.filter(mapped, fn x -> rem(x, 4) == 0 end)

  # Collect results
  Brook.to_list(filtered)
end
|> Channel.with_handler()
|> FiberPool.with_handler()
|> FiberPool.run!()
#=> [4, 8, 12, 16, ...]
```

### Producer functions

```elixir
use Skuld.Syntax
alias Skuld.Effects.Brook

comp do
  source <- Brook.from_function(fn ->
    case fetch_next_batch() do
      {:ok, items} -> {:items, items}
      :done -> :done
      {:error, e} -> {:error, e}
    end
  end)

  Brook.each(source, &process/1)
end
```

### I/O Batching in Brook

This example shows automatic batching of *nested* I/O - fetching users and their orders.
Each concurrent fiber fetches a user, then fetches that user's orders. Both operations
get batched across fibers, solving the N+1 query problem automatically:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Brook, Channel, FiberPool}

defmodule Order do
  defstruct [:id, :user_id, :total]
end

# Define typed query contracts
defmodule Queries do
  use Skuld.Query.Contract

  defquery fetch_user(id :: pos_integer()) :: map() | nil
  defquery fetch_orders(user_id :: pos_integer()) :: [map()]
end

defmodule User do
  defstruct [:id, :name, :orders]

  # Fetch a user and all their orders using typed Query.Contract calls
  # Each query operation can be batched with operations from other concurrent fibers
  defcomp with_orders(user_id) do
    user <- Queries.fetch_user(user_id)
    orders <- Queries.fetch_orders(user_id)
    %{user | orders: orders}
  end

  # Fetch multiple users with their orders using Brook
  defcomp fetch_users_with_orders(user_ids) do
    # chunk_size: 2 - small enough that there is still
    # concurrency...
    source <- Brook.from_enum(user_ids, chunk_size: 2)
    users <- Brook.map(source, &with_orders/1, concurrency: 3)
    Brook.to_list(users)
  end
end

# Implement the executor with typed callbacks
defmodule QueriesExecutor do
  @behaviour Queries.Executor

  @impl true
  def fetch_user(ops) do
    IO.puts("User fetch: #{length(ops)} users batched")
    Comp.pure(Map.new(ops, fn {ref, %Queries.FetchUser{id: id}} ->
      {ref, %User{id: id, name: "User #{id}", orders: nil}}
    end))
  end

  @impl true
  def fetch_orders(ops) do
    IO.puts("Order fetch: #{length(ops)} queries batched")
    Comp.pure(Map.new(ops, fn {ref, %Queries.FetchOrders{user_id: user_id}} ->
      {ref, [
        %Order{id: user_id * 10 + 1, user_id: user_id, total: 100},
        %Order{id: user_id * 10 + 2, user_id: user_id, total: 200}
      ]}
    end))
  end
end

User.fetch_users_with_orders([1, 2, 3, 4, 5])
|> Queries.with_executor(QueriesExecutor)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> FiberPool.run!()
# Prints:
#    User fetch: 3 users batched
#    Order fetch: 3 queries batched
#    User fetch: 2 users batched
#    Order fetch: 2 queries batched
#=> [%User{id: 1, orders: [%Order{...}, ...]}, %User{id: 2, ...}, ...]  # order preserved
```

Without automatic batching, fetching 5 users with orders would require 1 + 5 = 6 queries
(one for all users, one per user for orders) _or_ rearranging the code significantly.
With batching, fibers running concurrently
have their query operations combined: just 2 user fetches (batches of 3 and 2) and 2 order
fetches (same batches) - as defined by the `concurrency: 3` option.

**Why `chunk_size: 2`?** Brook.map's `concurrency` controls how many *chunks* process
concurrently. With the default `chunk_size: 100`, all 5 items would be in one chunk
and processed sequentially. Using `chunk_size: 2` means that the data is divided
into multiple chunks, and each chunk is its own concurrent unit, allowing their I/O operations to batch together.

`Brook.map` preserves input order even with `concurrency > 1` by using `put_async`/`take_async`
internally (see Channel section above for details on how this works).

Operations: `from_enum/2`, `from_function/2`, `map/3`, `filter/3`, `each/2`, `run/2`, `to_list/1`

**Backpressure:** Each stream stage uses a bounded channel buffer (default: 10).
When a buffer fills, the upstream producer blocks until the consumer catches up.
Configure with the `buffer` option: `Brook.map(source, &transform/1, buffer: 20)`.

### Performance vs GenStage

Skuld Brooks are optimized for throughput via transparent chunking (processing items
in batches of 100 by default). Here's how they compare to GenStage:

| Stages | Input Size | Skuld  | GenStage | Skuld Speedup |
|--------|------------|--------|----------|---------------|
| 1      | 1k         | 0.17ms | 53ms     | 312x          |
| 1      | 10k        | 1.6ms  | 57ms     | 36x           |
| 1      | 100k       | 15ms   | 594ms    | 38x           |
| 5      | 1k         | 0.79ms | 53ms     | 67x           |
| 5      | 10k        | 7ms    | 57ms     | 8x            |
| 5      | 100k       | 63ms   | 586ms    | 9x            |

*Run with `mix run bench/brook_vs_genstage.exs`*

**Stage count scaling (10k items):**

| Stages | Skuld   | GenStage | Winner   |
|--------|---------|----------|----------|
| 1      | 1.9ms   | 27ms     | Skuld    |
| 5      | 7ms     | 27ms     | Skuld    |
| 10     | 14ms    | 27ms     | Skuld    |
| 15     | 23ms    | 27ms     | Skuld    |
| 20     | 29ms    | 27ms     | GenStage |
| 30     | 44ms    | 28ms     | GenStage |

GenStage runs each stage in a separate process, so stages execute in parallel - total
time stays constant regardless of stage count. Skuld runs all stages cooperatively
in a single process, so time grows linearly (~1.5ms per stage). The crossover point
is around 15-20 stages for trivial transforms. CPU-heavy transforms would favor
GenStage (parallel execution across cores), while I/O-heavy transforms would favor
Skuld (automatic batching and non-blocking cooperative scheduling).

**Chunking vs I/O batching tradeoff:**

| Stages | Input | Skuld (chunked) | Skuld (chunk_size: 1) | GenStage |
|--------|-------|-----------------|----------------------|----------|
| 1      | 1k    | 0.17ms          | 3ms                  | 23ms     |
| 1      | 10k   | 1.6ms           | 27ms                 | 27ms     |
| 1      | 100k  | 15ms            | 276ms                | 414ms    |
| 5      | 1k    | 0.79ms          | 16ms                 | 23ms     |
| 5      | 10k   | 7ms             | 155ms                | 25ms     |
| 5      | 100k  | 63ms            | 1510ms               | 408ms    |

Skuld's default `chunk_size: 100` processes items in batches for ~17x better throughput,
but items within a chunk transform sequentially. Using `chunk_size: 1` enables true
concurrent transforms (and thus I/O batching), but loses the chunking speedup.

For **I/O-heavy workloads** (e.g., 10ms database calls), `chunk_size: 1` still wins
because batching N database calls into 1 query dominates the per-item overhead. For
**CPU-bound transforms**, the default chunking is clearly better.

### Architecture Tradeoffs

Skuld Brooks run in a **single BEAM process** with cooperative fiber scheduling,
while GenStage uses **multiple processes** with demand-based flow control. This
leads to different characteristics:

| Aspect        | Skuld Brook            | GenStage               |
|---------------|------------------------|------------------------|
| Scheduling    | Cooperative (fibers)   | Preemptive (processes) |
| Communication | Direct (shared memory) | Message passing        |
| Parallelism   | Single process         | Multi-process          |
| Best for      | I/O-bound pipelines    | CPU-bound pipelines    |
| Memory model  | Higher peak, chunked   | Lower, item-by-item    |
| Startup cost  | Minimal                | ~50ms process setup    |

**When to use each:**

- **Skuld Brook** excels at I/O-bound workloads where items flow through
  transformations quickly and automatic I/O batching (via `FiberPool`) can
  consolidate database queries or API calls. The single-process model eliminates
  message-passing overhead and enables order-preserving concurrent transforms.

- **GenStage** is better for CPU-bound pipelines where you need true parallelism
  across CPU cores. Each stage runs in its own process, enabling concurrent
  computation. The demand-based backpressure also provides finer-grained memory
  control for very large datasets.

- **Hybrid approach**: For CPU-intensive transforms within Skuld, use
  `FiberPool.task/1` to offload work to separate BEAM processes while keeping
  the pipeline coordination in Skuld.
