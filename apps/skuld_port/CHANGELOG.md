# Changelog

<!-- last-updated-against: ca199b2 -->

All notable changes to `skuld_port` will be documented in this file.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added

- **Port** — effect for dispatching parameterizable blocking calls to pluggable backends. Supports direct, module, function, effectful, test stub, fn handler, and stateful handler backends
- **Port.EffectfulFacade** — generates effectful dispatch facades from DoubleDown contracts. Supports single-module, combined, and separate contract+facade patterns
- **Adapter** — bridges effectful implementations to plain Elixir interfaces by wrapping effectful impls with handler stacks and `Comp.run!/1`
- **Adapter.EffectfulContract** — generates effectful `@callback` declarations from DoubleDown contracts
- **Command** — command execution effect with transaction wrapping
- **Transaction** — transaction wrapping effect with Ecto and Noop backends, environment state rollback
