# Changelog

<!-- last-updated-against: 97d0fef -->

All notable changes to `skuld_repo` will be documented in this file.

## [Unreleased]

### Changed

- **Ecto** is now a required rather than optional dependency — it was previously
  optional on the monolithic `skuld` package but is always required by
  `skuld_repo`.

### Fixed

- Use correct sibling version attribute for `skuld_port` Hex dep constraint.

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
