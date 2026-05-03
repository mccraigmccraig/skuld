# Changelog

All notable changes to Skuld will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Single-module contract+facade pattern: `use Skuld.Effects.Port.Facade` (no
  options) now folds contract definition, effectful behaviour, and dispatch
  facade into a single module. `defcallback` declares operations directly in
  the facade module, with `computation()`-wrapped `@callback` declarations
  and dispatch functions generated automatically.

- `Skuld.Effects.Port.Repo.InMemory` — closed-world in-memory Repo handler,
  thin wrapper around `DoubleDown.Repo.InMemory`. Authoritative for all
  bare-schema reads without a fallback. Supports writes, PK reads, clause
  reads, aggregates, bulk operations, preload, reload, and transaction
  rollback.

- `Skuld.Effects.Port.Repo.OpenInMemory` — open-world in-memory Repo handler,
  thin wrapper around `DoubleDown.Repo.OpenInMemory`. Authoritative for PK
  reads only; everything else falls through to a fallback function.

- `Skuld.Effects.Port.Repo.Stub` — stateless stub Repo handler, thin wrapper
  around `DoubleDown.Repo.Stub`. Writes apply changesets and return results
  but store nothing. Reads require a fallback function.

- Transaction effect (`Skuld.Effects.Transaction`) with `transact` and
  `rollback` operations. Supports env state rollback, nested savepoints,
  and optional database transaction wrapping via separate Noop and Ecto
  handlers.

- Extended `Skuld.Effects.Port.Repo.Contract` to match `DoubleDown.Repo`
  operations: opts-accepting write/read variants, explicit bang operations
  (`insert!/1,2`, `update!/1,2`, `delete!/1,2`), upsert (`insert_or_update`),
  raw SQL (`query/1,2,3` and `query!/1,2,3`), reload, preload, all_by, load,
  and stream.

### Changed

- Upgraded `double_down` dependency from `~> 0.54` to `~> 0.58`.

### Removed

- Auto-bang generation from effectful Port facades (`extract_success_type/1`
  and `has_ok_error_pattern?/1` removed in `double_down` 0.38). Bang variants
  must be declared as explicit `defcallback` declarations.

- Deprecated `Skuld.Effects.Port.Repo.Test` — use `Repo.Stub` instead.

## [0.23.0] — 2026-04-09

### Changed

- Upgraded `hex_port` dependency from `~> 0.14` to `~> 0.17`.
- Renamed generated facade key helper from `key/N` to `__key__/N`, matching
  the upstream hex_port rename. This avoids clashes with user-defined
  `defport key(...)` operations.

## [0.22.0] — 2026-04-04

### Changed

- Upgraded `hex_port` dependency from `~> 0.11` to `~> 0.14`.
- `Repo.Contract` now declares 16 operations (was 15) — added `insert_all/3`.
- `Repo.Test` and `Repo.InMemory` insert/update now check `changeset.valid?`
  before applying changes — invalid changesets return `{:error, changeset}`,
  matching real Ecto.Repo behaviour.
- `Repo.Test` and `Repo.InMemory` now use `HexPort.Repo.Autogenerate` for
  primary key and timestamp autogeneration — supports `:id` (integer
  auto-increment), `:binary_id` (UUID), parameterized types (`Ecto.UUID`,
  `Uniq.UUID`), `@primary_key false` schemas, and `inserted_at`/`updated_at`
  timestamp population.
- Removed custom PK helpers from `Repo.InMemory` (`get_primary_key`,
  `put_primary_key`, `next_id`, `safe_apply_changes`) in favour of the shared
  `HexPort.Repo.Autogenerate` module.

### Added

- `Repo.Contract.insert_all/3` — bulk insert operation, dispatched via
  fallback in both test adapters.
- `CHANGELOG.md` — project changelog compiled from git history.

## [0.21.0] — 2026-03-31

### Changed

- Simplified single-module Contract + Facade definition pattern — more compact
  module definitions when contract and facade live in the same module.

## [0.20.0] — 2026-03-31

### Changed

- Upgraded `hex_port` to v0.11.0.

### Fixed

- Fixed dynamic compilation warning.

## [0.19.0] — 2026-03-31

### Changed

- Upgraded `hex_port` to v0.10.0 — gains explicit `:contract` option for
  `use HexPort.Facade` with separate contract modules.

## [0.18.0] — 2026-03-31

### Added

- Support for same-module effectful Contract + Facade — a single module can
  now declare both the contract and the effectful facade.

### Changed

- Upgraded `hex_port` to v0.9.0 — gains single-module Contract + Facade
  support upstream.

## [0.17.0] — 2026-03-31

### Changed

- Introduced explicit `EffectfulContract` module — clearer separation of
  the effectful behaviour generation from the contract declaration.

## [0.16.0] — 2026-03-31

### Changed

- Extracted `Effects.Port.Facade` as the dispatch facade pattern.
- Renamed `Repo` to `Repo.Contract` + `Repo` facade — the contract declares
  operations, the facade provides the caller-facing API.
- Upgraded `hex_port` to v0.8.0 — gains built-in `Repo.Contract` with
  `Repo.Test` and `Repo.InMemory` test doubles, plus `MultiStepper`.

## [0.15.0] — 2026-03-30

### Changed

- `Repo.InMemory` fallback function now receives `(operation, args, state)`
  instead of `(operation, args)` — the state argument enables fallbacks that
  compose canned data with records inserted during the test.
- Upgraded `hex_port` to v0.7.0.
- Made `Repo.Test` and `Repo.InMemory` handlers more consistent.

## [0.14.0] — 2026-03-30

### Changed

- Consistent handler patterns for `Repo.Test` and `Repo.InMemory`.

## [0.13.0] — 2026-03-30

### Changed

- Upgraded `hex_port` to v0.6.0 — `HexPort.Contract.__using__/1` is now
  idempotent (safe to `use` multiple times).

## [0.12.1] — 2026-03-30

### Changed

- Upgraded `hex_port` to v0.3.1 — fixes Dialyzer `unknown_type` errors by
  expanding type aliases at macro time in `defport`.

## [0.12.0] — 2026-03-30

### Changed

- Updated `Skuld.Effects.Port.Contract` to use `HexPort.Contract` directly
  (no `.Port` generation).
- Updated documentation for Contract/Port separation.

## [0.11.1] — 2026-03-29

### Changed

- Pass `otp_app` option through `Port.Contract` to HexPort for plain dispatch.

### Added

- Remote `hex_port` hex dependency (previously vendored/inline).

## [0.11.0] — 2026-03-29

### Changed

- Moved effectful caller functions from `X` to `X.EffectPort` for symmetry
  with the HexPort/EffectPort architecture.
- Removed `Adapter.Plain` — plain dispatch is now HexPort's concern.
- Refactored `Port.Contract` to delegate to HexPort for plain layers.

## [0.10.0] — 2026-03-28

### Added

- `Repo.InMemory` — stateful in-memory Repo handler with read-after-write
  consistency for PK-based lookups.
- Stateful Port test handler functions via `Port.with_stateful_handler/4`.

### Changed

- Updated documentation with real stateful handler API and honest Mox
  comparison.
- Removed redundant `__port_effectful__?/0` from `Adapter.Plain`.

## [0.9.0] — 2026-03-28

### Changed

- Renamed `Adapter.Direct` to `Adapter.Plain` for consistent terminology.

## [0.8.3] — 2026-03-28

### Changed

- Redesigned `Adapter.Direct`: config-based dispatch with `otp_app`,
  `config_key`, and `default` options.
- Added `__port_effectful__?/0` returning `false` to Direct adapters.
- Documented testing plain hexagons with Mox against Port contract's Plain
  behaviour.

## [0.8.2] — 2026-03-28

### Changed

- Auto-detect effectful resolvers via `__port_effectful__?/0` marker — checks
  the return value, not just existence.
- Port log now accumulated directly in `State.log`, removing `Writer`
  dependency.

## [0.8.1] — 2026-03-28

### Fixed

- Credo compliance fixes.

## [0.8.0] — 2026-03-28

### Added

- Port-level dispatch logging via `Port.State` struct — logs are accumulated
  in handler state rather than using a separate Writer effect.

### Changed

- Removed logging from `Port.Repo` (now handled at the Port level).

## [0.7.2] — 2026-03-27

### Changed

- Unified Port dispatch into a single merged registry with default resolvers.
- Mixed handler modes (function and module-based) now work in the same
  registry.

## [0.7.1] — 2026-03-27

### Fixed

- `Port.with_handler` now merges nested registries instead of shadowing them.

## [0.7.0] — 2026-03-27

### Added

- `Port.Repo` — built-in Repo effect with `Repo.Test` (stateless) and
  `Repo.Ecto` (production) adapters.
- Custom `Writer` tag for `Repo.Test` dispatch logging.

### Changed

- `defport` no longer requires parentheses around the function signature.
- Added real-world comparison benchmarks.

## [0.6.0] — 2026-03-27

### Added

- Direct Port adapter — call effectful Ports with consumer stack for
  non-effectful (plain function) dispatch.

### Changed

- Effectful / Plain rename — clearer terminology for the two dispatch modes.
- Renamed generated Port modules for clarity.
- Updated documentation: replaced DB effect patterns with Transaction + Port
  patterns.

## [0.5.0] — 2026-03-26

### Added

- `Transaction` effect — for transactional boundaries without coupling to
  a specific DB implementation.
- `def_op_struct` — generates typed operation structs from effect definitions.

### Changed

- Inline effect constructor functions generated by `def_op` and
  `def_tagged_op`.
- Removed `DB` effect (replaced by Transaction + Port pattern).

## [0.4.0] — 2026-03-26

### Changed

- New minimal-allocation operation macros: `def_op` (renamed from
  `def_simple_op`), `def_tagged_op`, `def_op_struct`.
- Ported all built-in effects to new op macros: `Throw`, `Yield`, `Fresh`,
  `Random`, `Command`, `Port`, `Parallel`, `Reader`, `Writer`.
- Unified state keys to use sig atoms instead of tuples.
- Per-tag module-atom sigs for State effect performance.
- Added generic term encoding for EffectLogger JSON serialization.

### Fixed

- Performance improvements: inlining, per-tag sigs, progressive overhead
  benchmarks showing CPS parity discounting catch-frame tax.

## [0.3.1] — 2026-03-24

### Fixed

- Added `:mix` to Dialyzer PLT apps for mix task compatibility.

### Changed

- Documentation refresh with navigation injection.

## [0.3.0] — 2026-03-23

### Added

- `query do` macro — automatic concurrent batching of independent data
  fetches (inspired by Haxl).
- `Query.Contract` — declarative data-fetch contracts with `defquery`,
  struct-based operations, and batch execution.
- `Query.Cache` — within-batch request deduplication and caching with
  `cache: false` opt-out.
- `FiberPool` — fiber-based concurrency: `Fiber` struct, `FiberPool.task`,
  `FiberPool.fiber`, `FiberPool.ap` for applicative concurrency.
- Channels — rendezvous and buffered channels for fiber communication.
- `Stream` — effectful streaming with ordered concurrent processing.
- `Brook` — lightweight stream abstraction.
- Batch scheduling with `IBatchable` and `BatchSuspend`.
- Fiber deadlock detection, error structs, and structured cancellation.

### Changed

- `FiberPool.run` deprecated in favour of `Comp.run` with task supervisor.
- `alet` macro removed (superseded by `query`).
- Significant internal refactoring: `State` → `SchedulerState`,
  `EnvState` → `ChannelCoordinationState`.

## [0.2.3] — 2026-03-14

### Changed

- Improved Port review: better error locations and Throw handler docs.
- Split 'slightly insane effects' category in README.
- Moved `DB.Batch` to slightly insane effects category.

## [0.2.2] — 2026-03-14

### Added

- `Port.Provider` — implementation macro for generating modules that satisfy
  Port contracts.
- Port Consumer and Provider behaviours with documentation.

### Changed

- Bang variant control documented — `defport` `bang: false` option.

## [0.2.1] — 2026-03-14

### Added

- `Port.Contract` bang variant control — `bang: false` option on `defport` to
  suppress automatic bang variant generation.

## [0.2.0] — 2026-03-13

### Added

- `Port.Contract` — typed port contracts with `defport` macro for hexagonal
  architecture boundaries.
- Port dispatch with args list for `apply`-style invocation.
- Transactional state support.

### Changed

- Widened DB effect API.
- Batching + chunking improvements with better concurrency explanation.

## [0.1.26] — 2026-02-04

### Changed

- Major internal refactoring: extracted Fiber-related state into structs,
  simplified FiberPool communicable state with `MapSet`, extracted
  `ISentinel` additions, `IThrowable` protocol.
- `ExternalSuspend` and `InternalSuspend` refactored.
- Hidden many internal modules from documentation.

## [0.1.25] — 2026-02-02

### Fixed

- Fixed `AsyncComputation` bugs.
- Fixed nested batching.

## [0.1.24] — 2026-02-02

### Fixed

- Fixed scheduler bug in fiber execution.

### Changed

- Updated examples to be self-contained.
- Added streaming + batching test coverage.

## [0.1.23] — 2026-02-02

### Changed

- Removed `Process` dictionary usage from `AsyncComputation`.
- `FiberPool.task` now runs a thunk.
- Credo / Dialyzer compliance.

## [0.1.22] — 2026-02-02

### Added

- `Brook` — lightweight effectful stream abstraction.
- I/O batching demos and batching concurrency examples.

### Changed

- Allow rendezvous Channels.
- Concurrency floor lowered to 2 for Stream operations.
- Backpressure documentation.

## [0.1.21] — 2026-02-01

### Added

- Stream vs GenStage benchmark.
- Transparent chunking for streams.

### Fixed

- Fixed multiple resumption error in streaming.
- Memory efficiency improvements.

## [0.1.20] — 2026-02-01

### Fixed

- Fixed `Stream.map` concurrent ordering — results now preserve input order.
- Fixed O(n²) in `Stream.to_list`.

### Changed

- `FiberPool.fiber` and `FiberPool.task` API.

## [0.1.19] — 2026-02-01

### Added

- `Stream` — effectful streaming with concurrent `map`, `filter`, `flat_map`,
  and ordered concurrent processing.
- `Channel` — rendezvous and buffered channels for fiber-to-fiber
  communication.
- `IBatchable` and `BatchSuspend` for batch scheduling.
- `FiberPool` with fiber and task spawning.
- `Fiber` struct.

## [0.1.18] — 2026-01-31

### Changed

- Use `Map` for Port params.
- Credo compliance.

## [0.1.17] — 2026-01-29

### Fixed

- Improved Throw unwrapping in `try_catch`.

## [0.1.16] — 2026-01-28

### Added

- Port function handler — plain functions as Port implementations.
- `NonBlockingAsync` effect.
- Structured concurrency: fibers, fiber scheduling, `TaskHandler` and
  `FiberHandler`, `Scheduler` GenServer.
- `Await`, `AwaitSuspend`, `AwaitRequest` for async/await patterns.

### Changed

- Renamed `Query` to `Call`.
- Cancel remaining fibers when leaving structured concurrency boundary.
- Improved stacktraces and debugging support.

## [0.1.15] — 2026-01-23

### Added

- Computation cancellation support via `cancel_computations`.

### Fixed

- Proper `Cancelled` support in `AsyncComputation`.

## [0.1.14] — 2026-01-22

### Changed

- Renamed `AsyncRunner` to `AsyncComputation` for clarity.
- Split handler behaviours: `IHandle`, `IIntercept`, `IInstall` replace
  monolithic `IHandler`.
- Split `Random` into `Seed`/`Fixed` submodules.
- Split `Fresh` into `UUID7`/`Test` submodules.
- Split `AtomicState` into `Agent`/`Sync` submodules.
- Generalized catch clause parsing: tagged `{Module, pattern}` syntax for
  `Yield` interception.
- Handler installation syntax in catch clauses using bare module patterns.
- Added `TEST_PERFORMANCE.md` and `@tag :slow` for fast test profiles.

### Fixed

- Used `call_k` in `pure/1` for consistent exception handling.
- Fixed `Comp.scoped` documentation: `Suspend` does NOT trigger
  `leave_scope`.

## [0.1.13] — 2026-01-17

### Added

- `:data` field on `Suspend` — enables carrying data through suspensions.
- `:suspend` option on `Comp.with_scoped_state` for controlling suspension
  data storage.
- `transform_suspend` in `Env` for transforming suspensions.

## [0.1.12] — 2026-01-16

### Added

- Send responses back to caller in async computations.

## [0.1.11] — 2026-01-16

### Added

- `start_sync` and `resume_sync` for synchronous async computation control.

## [0.1.10] — 2026-01-15

### Added

- `AsyncRunner` effect — run effectful computations asynchronously in
  separate processes with suspend/resume lifecycle.
- EffectLogger examples and improved README documentation.
- Parallel effect examples.

### Changed

- Simplified `comp_block` macros, EffectLogger, and handler usage.
- Shared `TaskHelpers` extraction.
- More efficient `sequence`, `traverse`, and `each` implementations.
- Removed `Op` suffixes from operation names.

## [0.1.9] — 2026-01-13

### Added

- `Yield.respond` — bidirectional communication through yield/respond.

### Fixed

- Fixed `Map.get` default value handling.
- Fixed missing exception handling in handler dispatch.
- Fixed `put`/`tell`/`cas` null ambiguity in State effects.
- Fixed `AtomicState` call-twice bug.

### Changed

- Simplified `Yield.scoped` and `def_op`.

## [0.1.8] — 2026-01-13

### Added

- `Parallel` effect — run multiple computations concurrently.
- `Async` effect with `cancel` and `await_with_timeout`.
- `AtomicState` effect — thread-safe mutable state.
- `Random` effect — pure random number generation.
- `ChangesetPersist` effect — Ecto changeset persistence.

### Fixed

- Fixed `comp_block` regression.
- Fixed typing violations.
- Removed `Process.sleep` from tests.

## [0.1.7] — 2026-01-11

### Changed

- State key helpers.
- Only snapshot named effect states.

## [0.1.6] — 2026-01-11

### Added

- Effect state snapshots in loop marks for EffectLogger pruning.
- Eager log pruning for recursive loops.

### Changed

- Improved EffectLogger log cleanup and pruning.

## [0.1.5] — 2026-01-10

### Added

- `Command` effect — fire-and-forget side-effect dispatch.
- `EctoPersist` test/stub handler.

### Changed

- Improved `Query` effect API.
- Simplified `Fresh` effect.
- Writer tags in `EventAccumulator` effect.

## [0.1.4] — 2026-01-09

### Added

- Auto-lifting: computations automatically lift pure values into the
  effect context.
- `Comp.when`, `Comp.unless`, `Comp.each` helpers.
- Performance benchmarks (Evf+CPS comparison).

### Changed

- Unified `Reader` & `TaggedReader`, `Writer` & `TaggedWriter`,
  `State` & `TaggedState` — tagged variants are now the default.
- `def_op` uses atom field encoding/decoding.
- Improved catching of Elixir `raise`/`throw` — first-step errors converted
  to Throw.

## [0.1.3] — 2026-01-07

### Changed

- Switched to `uniq` library for UUID support.
- Improved EffectLogger README examples.

## [0.1.2] — 2026-01-07

### Added

- `Fresh` effect — pure unique ID generation (UUID7).
- `DBTransaction` effect with Ecto and Noop adapters.
- EffectLogger flat logging with scopes, JSON encoding/decoding of LogEntry.

### Changed

- ExDoc module grouping.
- Proper sentinel handling.

## [0.1.1] — 2026-01-05

### Changed

- Version tracking via `VERSION` file.

## [0.1.0] — 2026-01-05

### Added

- Initial release — extracted from Freyja.
- Core CPS-based algebraic effect system with `Comp` monad, `comp do` syntax,
  `<-` bind, `else` clause, and `catch` clause for effect interception.
- Built-in effects: `Throw`, `Yield`, `Reader`, `Writer`, `State`,
  tagged variants (`TaggedReader`, `TaggedWriter`, `TaggedState`).
- `EctoPersist` and `EventAccumulator` effects.
- `EffectLogger` — JSON-serializable effect execution logging.
- `Bracket` effect for resource management.
- `Query` effect for data fetching.
- `FxList` and `FxControlList` — effectful list operations.
- Benchmarks, Credo, Dialyzer, GitHub CI.
