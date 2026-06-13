# Changelog

<!-- last-updated-against: 957e6541f8399f8818a2adb9f60c17b22649676c -->

All notable changes to `skuld_query` will be documented in this file.

## [0.32.1] — 2026-06-10

### Added
- `README.md` with package overview, installation, and quick start.


- `batch-loading.md` recipe added to extras (shared from skuld package docs).

### Improved

- `Skuld.Query` `@moduledoc` now includes a package-level intro describing
  what `skuld_query` provides and linking to the architecture guide.

### Changed

- Tightened `double_down` constraint to `~> 0.59.0` (from `~> 0.58`) to ensure compatible API.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added
- `README.md` with package overview, installation, and quick start.


- **Query** — syntax module providing `query`, `defquery`, and `defqueryp` macros for automatic concurrent batching via dependency analysis
- **QueryContract** — typed batchable fetch contracts with `deffetch` declarations, executor wiring, and automatic batching via FiberPool
- **Query.Cache** — scoped request-level deduplication cache that wraps executors so identical queries return cached results
- **Query.QueryBlock** — macro desugaring query bindings into concurrently-awaitable fiber groups via `FiberPool.ap` (applicative functor pattern)
