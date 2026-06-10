# Changelog

<!-- last-updated-against: c84d21d -->

All notable changes to `skuld_repo` will be documented in this file.

## [Unreleased]

### Improved

- `Skuld.Repo` `@moduledoc` now includes a package-level intro describing
  what `skuld_repo` provides and linking to the architecture guide.

### Changed

- **Ecto** is now a required rather than optional dependency — it was previously
  optional on the monolithic `skuld` package but is always required by
  `skuld_repo`.
- Tightened `double_down` constraint to `~> 0.59.0` (from `~> 0.58`) — adds
  `DoubleDown.Repo.Stub` which was not available in 0.58.0.

### Fixed

- Use correct sibling version attribute for `skuld_port` Hex dep constraint.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added
- `README.md` with package overview, installation, and quick start.


- **Repo** — effectful dispatch facade for standard Ecto Repo operations, generated via Port.EffectfulFacade
- **Repo.Effectful** — effectful contract defining standard Ecto Repo operations as effects
- **Repo.Ecto** — Ecto-based executor
- **Repo.InMemory** — in-memory test implementation backed by DoubleDown
- **Repo.OpenInMemory** — non-isolated in-memory implementation for process-level tests
- **Repo.Stub** — stub with canned responses (wraps DoubleDown.Repo.Stub)
- **Repo.Test** — test helper wrapper
- **Repo.Contract** — underlying DoubleDown contract mirroring DoubleDown.Repo
