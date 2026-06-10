# Changelog

<!-- last-updated-against: c84d21d -->

All notable changes to `skuld_port` will be documented in this file.

## [Unreleased]

### Improved

- `Skuld.Effects.Port` `@moduledoc` now includes a package-level intro
  describing what `skuld_port` provides and linking to the architecture guide.
- `hexagonal-architecture.md` and `property-testing.md` recipes added to
  extras (shared from skuld package docs).

### Fixed

- Fixed `unwrap_defer` to use correct module path for `DoubleDown.Contract.Dispatch.Defer` — the
  guard was checking for the wrong module, so Defer structs from DD fakes were never unwrapped.

### Changed

- Tightened `double_down` constraint to `~> 0.59.0` (from `~> 0.58`) to ensure compatible API.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added
- `README.md` with package overview, installation, and quick start.


- **Port** — effect for dispatching parameterizable blocking calls to pluggable backends. Supports direct, module, function, effectful, test stub, fn handler, and stateful handler backends
- **Port.EffectfulFacade** — generates effectful dispatch facades from DoubleDown contracts. Supports single-module, combined, and separate contract+facade patterns
- **Adapter** — bridges effectful implementations to plain Elixir interfaces by wrapping effectful impls with handler stacks and `Comp.run!/1`
- **Adapter.EffectfulContract** — generates effectful `@callback` declarations from DoubleDown contracts
- **Command** — command execution effect with transaction wrapping
- **Transaction** — transaction wrapping effect with Ecto and Noop backends, environment state rollback
