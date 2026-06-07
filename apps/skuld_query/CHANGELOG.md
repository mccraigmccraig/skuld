# Changelog

<!-- last-updated-against: ca199b2 -->

All notable changes to `skuld_query` will be documented in this file.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added

- **Query** — syntax module providing `query`, `defquery`, and `defqueryp` macros for automatic concurrent batching via dependency analysis
- **QueryContract** — typed batchable fetch contracts with `deffetch` declarations, executor wiring, and automatic batching via FiberPool
- **Query.Cache** — scoped request-level deduplication cache that wraps executors so identical queries return cached results
- **Query.QueryBlock** — macro desugaring query bindings into concurrently-awaitable fiber groups via `FiberPool.ap` (applicative functor pattern)
