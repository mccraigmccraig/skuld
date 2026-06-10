# Project Norms

## 1. Coding Style

### 1.a — No Hacks

We do not implement hacky shortcuts or workarounds. When unexpected complexity
arises, stop and discuss to settle on the most appropriate solution. A
deliberate, well-reasoned fix beats a rushed patch every time.

### 1.b — Let It Crash

Take Elixir and Erlang's "let it crash" philosophy to heart. Expected domain
errors should be handled. No error should ever be silently captured and
ignored. If something is wrong, surface it.

### 1.c — Simple Code

Value simple, easy-to-reason-about code. Prefer stdlib functions where
available. Favour clarity over cleverness.

### 1.d — Named Structure over Raw Maps

As a program evolves, loose untyped Maps that are convenient for
exploratory code destroy local reasoning. Once a concept has firmed up,
extract it into a named, validated struct. Structs provide compile-time
key checks, explicit defaults, and a single source of truth for shape.

### 1.e — Purity Outside Handlers

In this library side effects are forbidden everywhere except inside
effect handlers. Never use the Process dictionary, application config
system (`Application.get_env` / `put_env`), or any other impure mechanism
outside of a handler. Handlers are the sole gatekeepers of impurity.

### 1.f — Pattern Match Structs

Prefer pattern matching over dot-access when destructuring struct fields.
Matching makes the fields being used explicit at the call site, surfaces
missing fields at compile time, and avoids the nil-safety ambiguity of dot
access on optional fields.

```elixir
# Prefer:
defp decorate(%ExternalSuspend{data: data, value: value} = suspend, env) do
  # use data, value, suspend
end

# Over:
defp decorate(suspend, env) do
  data = suspend.data
  value = suspend.value
  # use data, value, suspend
end
```

## 2. Code Hygiene

Before a piece of work is considered complete, all of the following must be
green and produce no warnings or changes:

```
mix format
mix test
mix credo
mix dialyzer
```

Fix any issues and iterate until clean. After that, add a description to the
`## [Unreleased]` section of the relevant package's `CHANGELOG.md`
following the existing format (`### Added`, `### Changed`, `### Fixed`,
`### Improved`, `### Removed`). Each package has its own changelog at
`apps/<package>/CHANGELOG.md`. When updating a CHANGELOG, also update the
`last-updated-against` SHA comment at the top of the file to the current
HEAD commit.

When adding a new function or API surface, the work must include unit tests.
If the addition introduces a sufficiently broad integration point (e.g. a
new effect, a new combinator, or cross-cutting behaviour), it must also
include integration tests.

When the work is complete and the CHANGELOG has been updated, commit the
changes leaving a clean working copy.

**Never** add or commit files that are not explicitly part of a change you
have been working on. Research documents, issue descriptions, and
planning notes left in the working copy are not to be committed —
even if they describe work that constitutes the current change. If a
file wasn't created as part of this change and isn't already staged,
leave it alone. If in doubt about the status of a particular file, ask.

### 2.a — Focused Commits

Keep commits small and single-concern. A commit should change one thing
and only one thing. Never mix concerns — for example, a commit
introducing a new helper module should not also refactor callers to use
it. Put the module in one commit, the refactor in another.

Separation of concerns makes commits easy to understand during review,
safe to revert individually, and amenable to rebasing and reordering
(e.g. cherry-picking a bugfix onto a different branch, or reordering a
refactor to sit after other platform changes in a stacked PR).

Good examples of focused commits:

- `feat: add JSDebug helper module` (new code only)
- `refactor: use JSDebug helper in ForeignSuspendPage and test` (caller changes only)
- `fix: pattern?=true in case/with clause match transformers` (single bugfix)
- `fix: use SkuldJS.async instead of call in run_slow test` (single semantic fix)

Counter-examples:

- Mixing a new module with caller refactoring in one commit
- Committing lock-file updates together with feature changes
- Squashing a bugfix into a feature commit

Lock-file updates and other mechanical changes should always be
separate commits (prefixed `chore:`).

## 3. Release Process

The project is an Elixir umbrella with seven independently-versioned packages.
Not all packages are released together — each follows its own cadence.

### 3.a — Determine which packages to release

For each package with unreleased changes in its `CHANGELOG.md`:

| Package | Publish after |
|---|---|
| `skuld` | — (no sibling deps) |
| `skuld_concurrency`, `skuld_port`, `skuld_process`, `skuld_durable` | `skuld` |
| `skuld_query` | `skuld`, `skuld_concurrency` |
| `skuld_repo` | `skuld`, `skuld_port` |

Packages must be published in dependency order. A leaf package that hasn't
changed does not need a release even if a dependency was released.

### 3.b — Pre-release checks (run from umbrella root)

```
mix format
mix test
mix credo
mix dialyzer
```

Also run `mix skuld.docs.nav` from each package being released:

```
cd apps/skuld && mix skuld.docs.nav
cd apps/skuld_concurrency && mix skuld.docs.nav
...

Fix any issues. If `mix skuld.docs.nav` produces changes, inspect and commit them.

### 3.c — Version and changelog

For each package being released:

1. Decide the new version (semver):
   - **Patch** (X.Y.Z+1) — backwards-compatible bug fixes
   - **Minor** (X.Y+1.0) — backwards-compatible new functionality
   - **Major** (X+1.0.0) — incompatible API changes
2. Move the `## [Unreleased]` section into a new `## [X.Y.Z]` section in
   that package's `CHANGELOG.md`. Update the `last-updated-against` SHA
   to the HEAD commit *before* the release commit — the last commit with
   actual content changes.
3. Update that package's `apps/<package>/VERSION` file.

Bump each package independently. A single release may include multiple
packages if changes cascade (e.g. a new feature in `skuld` used by
`skuld_concurrency`).

### 3.d — Commit and tag

Commit all VERSION and CHANGELOG changes together:

```
git commit -m "release: skuld v0.32.0, skuld_concurrency v0.1.0"
```

Tag each released package with its package-prefixed version:

```
git tag skuld-v0.32.0
git tag skuld_concurrency-v0.1.0
```

Tag naming convention: `<package>-v<version>`.

### 3.e — Publish to Hex

Use the publish script which checks each package's local VERSION against
hex.pm and publishes only those that are newer:

```
scripts/publish.sh --check   # dry run: see what would be published
scripts/publish.sh           # publish interactively (prompts for 2FA)
```

Packages are published in dependency order (skuld first, then
skuld_concurrency / skuld_port / skuld_process, then skuld_durable /
skuld_query, then skuld_repo).

### 3.f — Immutability

**Never** move a tag, force-push a tag, or change a release commit. Assume
the release has been pushed to hex.pm. If code changes are required, do a
patch release. If only documentation changes are required, those can be made
on hex.pm without a release.
