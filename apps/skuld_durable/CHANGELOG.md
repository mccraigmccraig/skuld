# Changelog

<!-- last-updated-against: ca199b2 -->

All notable changes to `skuld_durable` will be documented in this file.

## [0.32.0] — 2026-06-07

Initial release. Extracted from `skuld` v0.32.0.

### Added

- **SerializableCoroutine** — wraps a computation with EffectLogger to capture a JSON-serializable effect log. Supports cold resume from serialized state, enabling durable, pausable workflows
- **EffectLogger** — logs all effect invocations for serialization, replay, and audit. Captures effect state snapshots and full effect entries as JSON-serializable structs
