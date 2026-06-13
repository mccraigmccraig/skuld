# Changelog

<!-- last-updated-against: 957e6541f8399f8818a2adb9f60c17b22649676c -->

All notable changes to `skuld_process` will be documented in this file.

## [0.32.1] — 2026-06-10

### Added
- `README.md` with package overview, installation, and quick start.


- `docs/effects/parallel.md` — covers `Parallel.all`, `race`, `map`, production
  and sequential handlers, error handling, and catch syntax.
- `docs/effects/atomic-state.md` — covers tagged states, Agent and Sync
  handlers, compare-and-swap, and catch syntax.

### Fixed

- `Skuld.Effects.Parallel` `@moduledoc` now includes a package-level intro
  describing what `skuld_process` provides and linking to the architecture guide.
- `mix.exs` description no longer claims to provide `Task` effect (which lives
  in `skuld_concurrency`). Now reads "Parallel and AtomicState effects."

### Changed

- Added `main: "parallel"`, `extras`, and `groups_for_extras` to `mix.exs`
  docs config. skuld_process previously had no doc pages.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added
- `README.md` with package overview, installation, and quick start.


- **Task** — Elixir Task integration for running computations in separate processes
- **Parallel** — multi-process parallel execution with result collection
- **AtomicState** — cross-process atomic state via `:atomics` with Agent and Sync backends
