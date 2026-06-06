# FiberPool

<!-- nav:header:start -->
[< Coroutine](coroutine.md) | [Up: Coroutines & Concurrency](yield.md) | [Index](../../README.md) | [Channel & Brook >](channel-brook.md)
<!-- nav:header:end -->

FiberPool is a cooperative scheduler that runs multiple `Coroutine`
fibers concurrently within a single BEAM process. It manages suspension,
resumption, deadlock detection, and structured concurrency.

## Starting fibers

```elixir
comp do
  # Spawn concurrent fibers
  task_a <- FiberPool.fiber(slow_operation_a())
  task_b <- FiberPool.fiber(slow_operation_b())

  # Wait for results
  a <- FiberPool.await(task_a)
  b <- FiberPool.await(task_b)
  {a, b}
end
|> FiberPool.with_handler()
|> Comp.run!()
```

`FiberPool.fiber/1` spawns a new fiber. The parent continues executing.
`FiberPool.await/1` suspends the parent until the child fiber completes.

## Await patterns

```elixir
result <- FiberPool.await!(fiber)             # raises on error
{:ok, result} <- FiberPool.await(fiber)       # ok/error tuple
results <- FiberPool.await_all([f1, f2, f3])  # wait for all
```

## Structured concurrency

`FiberPool.scope/1,2` ensures all fibers spawned within the scope
complete before the scope exits. If any fiber errors, the scope
cancels remaining fibers:

```elixir
FiberPool.scope(fn ->
  f1 <- FiberPool.fiber(work_a())
  f2 <- FiberPool.fiber(work_b())
  FiberPool.await_all([f1, f2])
end)
```

## Mapping

```elixir
results <- FiberPool.map(items, fn item ->
  process(item)   # each item runs in its own fiber
end)
```

## Deadlock detection

If all fibers suspend waiting on each other with no external progress
possible, FiberPool detects the deadlock and raises:

```elixir
{:error, {:deadlock, _diagnostic}} = FiberPool.await_all(fibers)
```

## Handler

```elixir
computation |> FiberPool.with_handler()
```

Handler order is independent of other effects — each effect manages
its own handler.

| Operation | Purpose |
|-----------|---------|
| `FiberPool.fiber(comp)` | Spawn a new fiber |
| `FiberPool.await/1`, `await!/1` | Wait for fiber result |
| `FiberPool.await_all/1` | Wait for all fibers |
| `FiberPool.scope/1,2` | Structured concurrency boundary |
| `FiberPool.map/2` | Concurrent map over a collection |

<!-- nav:footer:start -->

---

[< Coroutine](coroutine.md) | [Up: Coroutines & Concurrency](yield.md) | [Index](../../README.md) | [Channel & Brook >](channel-brook.md)
<!-- nav:footer:end -->
