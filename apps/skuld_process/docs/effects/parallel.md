# Parallel

<!-- nav:header:start -->
[AtomicState >](atomic-state.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Fork-join concurrency with automatic task lifecycle management. Each
operation spawns tasks, awaits results, and cleans up automatically —
no handles to track or boundaries to manage.

## Basic usage

```elixir
use Skuld.Syntax
alias Skuld.Effects.{Parallel, Throw}

comp do
  Parallel.all([
    comp do expensive_work_1() end,
    comp do expensive_work_2() end,
    comp do expensive_work_3() end
  ])
end
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [:result1, :result2, :result3]
```

## Operations

- **`Parallel.all(comps)`** — Run all computations in parallel, return results
  in order. Fails with `{:error, {:task_failed, reason}}` if any task fails.
- **`Parallel.race(comps)`** — Run all computations, return the first to
  complete successfully. Cancels the remaining tasks. If all tasks fail,
  returns `{:error, :all_tasks_failed}`.
- **`Parallel.map(items, fun)`** — Map a function over items in parallel.
  The function receives each item and returns a computation. Results are
  returned in input order. Fails on first error.

## Handlers

- **`Parallel.with_handler/1`** — Production handler using
  `Task.Supervisor`. Creates a supervisor that manages all tasks; stopped
  when the handler scope exits.
- **`Parallel.with_sequential_handler/1`** — Test handler that runs
  computations synchronously in order. Deterministic, no process overhead.

## Error handling

| Operation | On task failure |
|-----------|----------------|
| `all/1` | Stops waiting, returns `{:error, {:task_failed, reason}}` |
| `race/1` | Ignores the failure, keeps waiting for other tasks. Returns `{:error, :all_tasks_failed}` only if every task fails |
| `map/2` | Stops waiting, returns `{:error, {:task_failed, reason}}` |

## BEAM process constraints

Child tasks receive a **snapshot of `env` at fork time**. Changes made by
child tasks don't propagate back to the parent. For shared mutable state
across parallel tasks, use `AtomicState` (Agent-backed handler) instead of
the regular `State` effect.

## Catch syntax

```elixir
comp do
  Parallel.all([...])
end
|> Comp.run!(
  catch:
    Parallel -> nil          # production handler (Task.Supervisor)
    Parallel -> :sequential  # test handler (runs sequentially)
)
```

<!-- nav:footer:start -->

---

[AtomicState >](atomic-state.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
