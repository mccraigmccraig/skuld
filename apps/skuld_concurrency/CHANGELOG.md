# Changelog

<!-- last-updated-against: ca199b2 -->

All notable changes to `skuld_concurrency` will be documented in this file.

## [Unreleased]

### Added

- `liveview.md` and `batch-loading.md` recipes added to extras (shared from
  skuld package docs).

### Improved

- `Skuld.Coroutine` `@moduledoc` now includes a package-level intro describing
  what `skuld_concurrency` provides and linking to the architecture guide.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added

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
