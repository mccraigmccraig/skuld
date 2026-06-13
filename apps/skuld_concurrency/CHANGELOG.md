# Changelog

<!-- last-updated-against: 766af198cc5edaf777292521039079c99d0f6826 -->

All notable changes to `skuld_concurrency` will be documented in this file.

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
