# Changelog

<!-- last-updated-against: a59c3e8ffe59fd11bf98f3644406b6073f0dbf9b -->

All notable changes to `skuld_concurrency` will be documented in this file.

## [0.41.0] — 2026-06-16

### Added

- `Skuld.PageMachine.Spindle` — named concurrent sub-computations that run
  as FiberPool fibers. `Spindle.fork(:key, computation)` creates a fiber and
  registers the key for event routing. `Spindle.Mappings` struct maintains
  bidirectional key↔fiber_id maps.
- `Skuld.Comp.InternalSuspend.FiberYield` — a new suspension payload for
  fiber-level yields within a FiberPool. When a fiber calls `Yield.yield`,
  the FiberYield handler produces an `InternalSuspend` instead of an
  `ExternalSuspend`, keeping the fiber in the pool while other fibers run.
- `Skuld.FiberPool.Server` — an always-on process hosting a multi-fiber
  cooperative scheduler with bidirectional message passing. Starts with
  named computations as fibers, routes `FiberYield` suspensions to the
  caller, and accepts resume/cancel messages.
- `Skuld.FiberPool.Scheduler.RoundResult` — a struct replacing the sum-type
  return of `Scheduler.run/2`. Captures all concurrent scheduler states
  simultaneously: suspended yields, completions, all_done, waiting_for_tasks,
  batch_ready. `run_loop` accumulates yields as it goes and only returns
  at quiescence.
- `Skuld.Effects.FiberPool.handler/0` — public handler accessor for
  installing the FiberPool effect handler without the drain_pending wrapper.
- Multi-arity `/3` callbacks in `PageMachine.__using__/1`: `(spindle_key,
  value, socket)`. `/2` callbacks still supported for single-spindle pages.
- `def_pipe_event` now supports `:into` option for routing events to a
  specific spindle key.

### Changed

- `Scheduler.run/2` returns `%RoundResult{}` instead of sum-type tuples.
  All callers (`Main`, `Server`) updated accordingly.
- Server uses non-blocking `receive` with `after 0` — only blocks on caller
  input when all fibers are suspended on `FiberYield` with no tasks running.
- `:fiber_cancel` now cancels the target fiber via `Coroutine.cancel` and
  sends `%Cancelled{}` to the caller.

### Removed

- `Skuld.PageMachine.SyncPageMachine` (formerly `Skuld.Coroutine.PageMachine`).
  Synchronous in-process page machines are incompatible with the Spindle model,
  which requires its own process to keep running between yield and resume.
  Use `Skuld.PageMachine` for all page flows.

### Changed

- `Skuld.PageMachine.AsyncPageMachine` renamed to `Skuld.PageMachine`.
  With SyncPageMachine removed, there's only one PageMachine.

## [0.40.0] — 2026-06-14

### Added

- `def_pipe_event` now accepts an optional `:before` callback —
  `(socket -> socket)` — called before the event is piped to the
  PageMachine. Useful for setting a loading spinner on async page machines.

## [0.39.0] — 2026-06-14

### Changed

- `def_pipe_event/2` default value changed from `{:ok, params}` to
  `{event, params}`. The event name provides context on the computation
  side — matching Phoenix's own `handle_event/3` contract.

## [0.38.0] — 2026-06-14

### Added

- `PageMachine.SyncPageMachine.def_pipe_event/2` and `def_pipe_event/4` macros
  generate `handle_event/3` clauses that pipe Phoenix events into the
  PageMachine as Yield resume values. Auto-imported via `use PageMachine`.
- `PageMachine.AsyncPageMachine.def_pipe_event/2` and `def_pipe_event/4`
  macros provide the same `handle_event/3` generation for async page machines,
  with an identical signature. Auto-imported via `use AsyncPageMachine`.

## [0.37.0] — 2026-06-13

### Changed

- `PageMachine.SyncPageMachine.run/4` takes an explicit assign key as a required
  positional parameter instead of storing in an implicit `:pm` key.
- `PageMachine.SyncPageMachine.cancel/2` now accepts a socket parameter (matching
  `run/3`).
- Page machine struct is now stored in assigns on every dispatch outcome,
  not just yield.


## [0.36.0] — 2026-06-13

### Added

- `Skuld.PageMachine.SyncPageMachine` — synchronous callback-based page-machine
  for LiveView integration. Callbacks are provided once at mount, subsequent
  resumes are one-liners. Run in-process with no separate BEAM process.
- `AsyncPageMachine.run/2` and `AsyncPageMachine.run_sync/2` now take
  `tag` as a required positional argument instead of a keyword option.
- `Skuld.PageMachine.AsyncPageMachine` renamed from `PageMachine`.


## [0.35.0] — 2026-06-13

### Added

- `Skuld.PageMachine.SyncPageMachine` — synchronous in-process page-machine
  wrapping `Skuld.Coroutine`. Returns raw sum types from `run/1-2` and
  `cancel/1-2`, with a `dispatch/1` helper for converting to tagged tuples
  (`{:yield, :complete, :error, :cancel}`). The in-process counterpart to
  `AsyncPageMachine`.


## [0.34.0] — 2026-06-13

### Added

- `Skuld.PageMachine.AsyncPageMachine` — `use` macro that generates `handle_info/2`
    clauses from callback options, eliminating LiveView boilerplate. Includes
    `run/2-3` and `cancel/1` delegation. Full test suite covering all callback
    combinations and edge cases.
  combinations and edge cases.

### Changed

- **Breaking**: `AsyncCoroutine.run/2` and `AsyncCoroutine.run_sync/2` now
  take `tag` as a required positional argument instead of a keyword option.
  `AsyncCoroutine.run(computation, :my_tag)` replaces
  `AsyncCoroutine.run(computation, tag: :my_tag)`. Convenience 2-arity
  wrappers added for both start and resume variants.

## [0.33.0] — 2026-06-13

### Improved

- `README.md` enriched with capability descriptions for each component
  (Coroutine, FiberPool, Channel, Brook, AsyncCoroutine, Task) and a
  concurrent stream-processing example with links to deeper reading.

## [0.32.1] — 2026-06-10

### Added
- `README.md` with package overview, installation, and quick start.


- `liveview.md` and `batch-loading.md` recipes added to extras (shared from
  skuld package docs).

### Improved

- `Skuld.Coroutine` `@moduledoc` now includes a package-level intro describing
  what `skuld_concurrency` provides and linking to the architecture guide.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added
- `README.md` with package overview, installation, and quick start.


- **Coroutine** — cooperative fiber primitive with sum-type state machine (Pending, InternalSuspended, ExternalSuspended, ForeignSuspended, ForeignSuspensions, Completed, Errored, Cancelled)
- **FiberPool** — cooperative fiber scheduler with structured concurrency (fiber, await!, await_all!, await_any!, scope, cancel), automatic batch collection and dispatch
- **Channel** — bounded channels with suspending put/take, backpressure, sticky error propagation, async variants
- **Brook** — high-level streaming API with sources, transforms (map, filter, flat_map), and sinks (to_list, run), with configurable concurrency
- **AsyncCoroutine** — runs computations in separate processes, bridges yields/results back via messages. Designed for LiveView and other non-effectful contexts
- **Yield** — coroutine-style suspension effect for pausable workflows
- **Task** — Elixir Task integration for running computations in separate processes
- **ForeignResolver** — protocol for resolving ForeignSuspend values across platforms (e.g. JS Promises in Hologram)
- **InternalSuspend** — sentinel struct and ISentinel implementation for internal scheduler suspensions (Batch, Channel, Await)
- **ISentinel** implementation for `InternalSuspend`
