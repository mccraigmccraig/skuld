# Changelog

<!-- last-updated-against: ca199b2 -->

All notable changes to `skuld_repo` will be documented in this file.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added

- **Repo** — effectful dispatch facade for standard Ecto Repo operations, generated via Port.EffectfulFacade
- **Repo.Effectful** — effectful contract defining standard Ecto Repo operations as effects
- **Repo.Ecto** — Ecto-based executor
- **Repo.InMemory** — in-memory test implementation backed by DoubleDown
- **Repo.OpenInMemory** — non-isolated in-memory implementation for process-level tests
- **Repo.Stub** — stub with canned responses (wraps DoubleDown.Repo.Stub)
- **Repo.Test** — test helper wrapper
- **Repo.Contract** — underlying DoubleDown contract mirroring DoubleDown.Repo
