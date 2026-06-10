# Changelog

<!-- last-updated-against: 0b88768 -->

All notable changes to `skuld_durable` will be documented in this file.

## [0.32.1] — 2026-06-10

### Added
- `README.md` with package overview, installation, and quick start.


- `docs/effects/serializable-coroutine.md` — covers building durable coroutines,
  running (fresh, live resume, cold resume), serializing/deserializing logs.
- `durable-computation.md` recipe added to extras (shared from skuld package docs).

### Improved

- `Skuld.SerializableCoroutine` `@moduledoc` now includes a package-level intro
  describing what `skuld_durable` provides and linking to the architecture guide.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added
- `README.md` with package overview, installation, and quick start.


- **SerializableCoroutine** — wraps a computation with EffectLogger to capture a JSON-serializable effect log. Supports cold resume from serialized state, enabling durable, pausable workflows
- **EffectLogger** — logs all effect invocations for serialization, replay, and audit. Captures effect state snapshots and full effect entries as JSON-serializable structs
