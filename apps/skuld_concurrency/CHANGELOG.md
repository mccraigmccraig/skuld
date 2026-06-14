# Changelog

<!-- last-updated-against: 4e98f6c4fcb28ab0fe41207ce173ed7006cb1406 -->

All notable changes to `skuld_concurrency` will be documented in this file.

## [0.39.0] — 2026-06-14

### Changed

- `def_pipe_event/2` default value changed from `{:ok, params}` to
  `{event, params}`. The event name provides context on the computation
  side — matching Phoenix's own `handle_event/3` contract.

## [0.38.0] — 2026-06-14

### Added

- `Coroutine.PageMachine.def_pipe_event/2` and `def_pipe_event/4` macros
  generate `handle_event/3` clauses that pipe Phoenix events into the
  PageMachine as Yield resume values. Auto-imported via `use PageMachine`.
- `AsyncCoroutine.AsyncPageMachine.def_pipe_event/2` and `def_pipe_event/4`
  macros provide the same `handle_event/3` generation for async page machines,
  with an identical signature. Auto-imported via `use AsyncPageMachine`.

## [0.37.0] — 2026-06-13

### Changed

- `Coroutine.PageMachine.run/4` takes an explicit assign key as a required
  positional parameter instead of storing in an implicit `:pm` key.
- `Coroutine.PageMachine.cancel/2` now accepts a socket parameter (matching
  `run/3`).
- Page machine struct is now stored in assigns on every dispatch outcome,
  not just yield.


## [0.36.0] — 2026-06-13

### Added

- `Skuld.Coroutine.PageMachine` — synchronous callback-based page-machine
  for LiveView integration. Callbacks are provided once at mount, subsequent
  resumes are one-liners. Run in-process with no separate BEAM process.
- `AsyncPageMachine.run/2` and `AsyncPageMachine.run_sync/2` now take
  `tag` as a required positional argument instead of a keyword option.
- `Skuld.AsyncCoroutine.AsyncPageMachine` renamed from `PageMachine`.


## [0.35.0] — 2026-06-13

### Added

- `Skuld.Coroutine.PageMachine` — synchronous in-process page-machine
  wrapping `Skuld.Coroutine`. Returns raw sum types from `run/1-2` and
  `cancel/1-2`, with a `dispatch/1` helper for converting to tagged tuples
  (`{:yield, :complete, :error, :cancel}`). The in-process counterpart to
  `AsyncPageMachine`.


## [0.34.0] — 2026-06-13

### Added

- `Skuld.AsyncCoroutine.AsyncPageMachine` — `use` macro that generates `handle_info/2`
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
