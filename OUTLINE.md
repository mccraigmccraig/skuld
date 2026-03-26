# Skuld Documentation Outline

Progressive-disclosure structure: each layer builds on the previous and is
self-contained at its depth. A reader can stop at any layer and have gotten
value.

The audience throughout is an experienced Elixir developer who has not
encountered algebraic effects before.

---

## The README

The README is the front door - the first thing someone sees on GitHub or
Hex.pm. It should do the standard open-source README job and then hand off
to the docs. It is *not* a separate document from the documentation; it is
Layer 0 - the hook that draws readers into the progressive-disclosure
narrative.

### Structure

1. **One-line description** - "Evidence-passing Algebraic Effects for Elixir"
   (as now).
2. **The elevator pitch** (2-3 sentences) - What problem does Skuld solve?
   Frame in terms of testing, coupling, and determinism - not in terms of
   algebraic effects theory. The reader should think "I have that problem"
   before they think "what's an algebraic effect?"
3. **The key insight** (1 short paragraph) - Instead of pure vs side-effecting,
   you get pure, effectful, and side-effecting. Domain code uses effects but
   stays pure. Same code, different handlers, different behaviour.
4. **Quick example** - Minimal `comp` block with State + Reader. Show it
   running with production-style handlers, then with test handlers, to
   demonstrate the pitch concretely. Keep it short enough to fit on one
   screen.
5. **Installation** - `mix.exs` dependency.
6. **What can it do?** - The side-effect / effectful-equivalent table (as now,
   but split into two tiers - see "Two Tiers" below).
7. **Documentation links** - Signpost into the docs, following the
   progressive-disclosure layers: "New to algebraic effects? Start with
   [Why Effects?](...). Ready to code? Jump to [Getting Started](...)."
8. **Demo application** - TodosMcp link (as now).
9. **License**.

The README replaces the current Layer 3 "Getting Started" as the primary
entry point. Layer 3 in the docs becomes a more thorough tutorial that the
README's quick example leads into.

---

## Two Tiers: Foundational Effects and Advanced Effects

Elixir developers tend to be pragmatic and conservative about new
abstractions. Jose Valim's design philosophy explicitly postpones
complexity "to only when we need them, if we need them"; the BEAM culture
of "let it crash" favours structural simplicity over sophisticated
abstraction; even the core team's own type system is being introduced
over multiple years with explicit "we can drop this" escape hatches.

(Note: the failure of monad libraries like Witchcraft in Elixir and
similar efforts in Clojure is *not* evidence of this conservatism -
monads are impractical in dynamically typed languages because without
compiler support you can't keep track of the explosion of nested types.
That's a fundamental impedance mismatch, not a cultural preference.
Skuld's algebraic effects are different: there is a single computation
type with auto-lifting, so there's no type-level bookkeeping. The `comp`
macro plays naturally in a dynamically typed language in a way that
`Monad.bind(Maybe.just(Either.right(...)))` never could.)

Algebraic effects are still a significant departure from "normal"
Elixir, and the effect library naturally splits into two tiers:

### Foundational Effects

Effects that solve problems every Elixir developer recognises. They feel
like well-structured Elixir code with better testability. A reader who
stops here has already gotten substantial value.

- State, Reader, Writer
- Throw, Bracket
- Fresh, Random
- DB, Command, EventAccumulator
- Port, Port.Contract, Port.Provider
- Parallel, AtomicState, AsyncComputation
- FxList, FxFasterList

### Advanced Effects

Effects that use Skuld's control-flow capabilities (CPS, continuations) to
do things that aren't possible with normal Elixir. These build on
cooperative fibers and are genuinely novel - they question the assumption
that BEAM processes are the only concurrency primitive you need.

The documentation should frame these honestly: "These are more
adventurous. They enable things that are difficult or impossible with
standard BEAM patterns, but they also introduce concepts (fibers,
channels, cooperative scheduling) that may be unfamiliar. The foundational
effects stand on their own - you don't need these to get value from Skuld."

- Yield (coroutines / suspend-resume)
- FiberPool (cooperative fibers, IO batching)
- Channel (bounded channels with backpressure)
- Brook (streaming on channels)
- Query / deffetch (batchable queries via FiberPool)
- EffectLogger (serializable coroutines)

The partition isn't about quality or importance - it's about how much
conceptual departure the reader needs to accept. The advanced effects are
where Skuld does things no other Elixir library can do, but a reader needs
to trust the foundational layer first.

---

## Layer 1: Why (The Problem)

**Goal:** The reader recognises a problem they already have, before any mention
of algebraic effects or Skuld. Start from patterns they already know and
value, then show where those patterns run out.

### What we already do well

- **Functional core / imperative shell** - The well-known pattern (Gary
  Bernhardt, 2012): push side effects to the edges, keep business logic
  pure. Extract pure data transformations, validations, and calculations
  into modules with no dependencies on IO, databases, or external services.
  This is good practice and widely adopted in the Elixir community.
- **Context / Service / Model layers** - Phoenix contexts, domain services,
  Ecto schemas. The standard layered architecture separates data
  representation from persistence from web concerns.
- **Extracting pure functions is always worthwhile** - If a function takes
  data and returns data with no side effects, keep it that way. Nothing
  here replaces that. Pure functions are the foundation.

### Where these patterns run out

- **The orchestration layer** - Between the pure core and the imperative
  shell sits domain orchestration: "fetch the user, check their
  permissions, load their subscription, compute the price, write the
  invoice, send the email." Each step is simple, but the *composition* is
  side-effecting because it depends on the database, the payment provider,
  the mailer. This orchestration logic is genuinely domain logic - it
  encodes business rules about what happens in what order, what to do when
  a step fails, what constitutes a valid state transition. But it can't
  live in the pure core because it needs IO at every step.
- **The orchestration layer is often the bulk of the interesting code** -
  The pure calculations (pricing rules, validation logic) are typically
  straightforward. The hard part - the part that has the most business
  rules, the most edge cases, and the most bugs - is the orchestration
  that ties them together. And that's exactly the part that's hardest to
  test, because it's wired to infrastructure.
- **The testing problem** - To test orchestration code you need the
  infrastructure it depends on. Mocks and stubs are fragile, couple tests
  to implementation details, and don't compose (mocking A while also
  mocking B requires knowing how they interact). Property-based testing of
  side-effecting orchestration is essentially impossible - you can't
  generate random sequences of "fetch user, check permissions, write
  invoice" and verify invariants if each step hits a real database.
- **The coupling problem** - The orchestration layer is tangled with
  infrastructure choices. Swapping Postgres for SQLite, or an HTTP client
  for a fake, or a payment provider for a test double, requires changing
  domain code - the very code that encodes your business rules.
- **The determinism problem** - Code that generates UUIDs, reads the clock,
  or calls `:rand` is non-deterministic. Reproducing a bug means
  reproducing the exact sequence of side effects that led to it.
- **Dependency injection helps but doesn't compose** - You can pass in a
  repo module or a behaviour implementation. But DI is manual plumbing,
  it doesn't compose (stacking multiple injected dependencies gets
  unwieldy), and it can't express control flow changes (what if you want
  to retry on failure? suspend and resume later? batch IO across
  concurrent operations?).

### What would ideal look like?

Domain orchestration code that is **pure** - no side effects, fully
deterministic, trivially testable - but can still **express** database
access, external service calls, randomness, error handling, and
concurrency. Test it with pure in-memory handlers. Run it with real ones.
Same code, different interpretations. The pure functional core expands to
include the orchestration layer, and the imperative shell shrinks to just
the handler implementations.

*No code in this section, or at most a tiny before/after sketch showing
the same orchestration function running with two different handler stacks.*

## Layer 2: What (The Concept)

**Goal:** The reader understands the algebraic effects idea - not Skuld's API,
but the general concept - well enough to predict roughly how things should work.
This layer bridges from the problem (Layer 1) to the solution: the
orchestration layer *can* be pure, if we change what "pure" means.

- **The functional-core boundary is in the wrong place** - The traditional
  split puts orchestration in the imperative shell because it *depends on*
  side effects. But the orchestration logic itself isn't inherently
  side-effecting - it's domain logic that *uses* things that happen to be
  side-effecting. The question is: can we express "fetch the user" without
  actually fetching the user?
- **Effects as requests** - Yes. An effectful function doesn't *do* the side
  effect. It *requests* it. "Fetch user 42" is a description of what's
  needed, not an action that hits the database. The function remains pure -
  it's a plan, not an execution.
- **Handlers as interpreters** - A handler decides what a request means. One
  handler talks to Postgres; another keeps an in-memory map. A third logs
  every request for replay. The effectful orchestration code doesn't know
  or care which handler is installed.
- **Three kinds of code** - This gives us a new layer: pure functions (no
  effects), effectful functions (request effects but don't perform them),
  and side-effecting handlers (actually do the IO). The orchestration layer
  moves from the imperative shell into the effectful middle layer - still
  pure, now testable.
- **Composition** - Handlers stack. A computation can use State, Reader, and
  DB simultaneously. Each handler manages its own concern. This is where
  effects differ from dependency injection: the composition is handled by
  the framework, not by manual plumbing.
- **The payoff** - One codebase, multiple interpretations: production handlers
  for real IO, test handlers for deterministic in-memory execution. The
  same orchestration function that processes a payment in production can be
  property-tested with hundreds of random inputs, because the "database"
  is a pure map and the "payment provider" is a deterministic stub.
- **A word about control flow** - Some effects don't just return a value - they
  change what happens next. Throwing discards the rest of the computation.
  Yielding pauses it. This is where algebraic effects go beyond what's
  possible with simple dependency injection - but you don't need control
  effects to get started. The foundational effects already solve the
  testing and coupling problems from Layer 1.
- **Skuld's approach in one paragraph** - Evidence-passing (handlers in a map,
  O(1) lookup) with CPS for control effects. Computations are functions, not
  data structures. Single unified type, `comp` macro for ergonomic sequencing.

*Conceptual diagrams, maybe a small pseudocode sketch. Still no real Skuld API.*

## Layer 3: Getting Started

**Goal:** The reader can write and run their first Skuld computation. This is
the tutorial that the README's quick example leads into.

- **Setup** - `mix.exs` dependency, `use Skuld.Syntax`.
- **Your first computation** - The `comp` block, `<-` for effectful binds, `=`
  for pure matches, auto-lifting of the final expression.
- **Pure values** - `Comp.pure/1`, auto-lifting, why the last expression
  doesn't need `return`.
- **Using an effect** - `State.get()`, `State.put()`. What happens when you
  call them (you get a computation, not a value).
- **Installing a handler** - `State.with_handler(initial_value)`. The
  computation is still inert until you run it.
- **Running** - `Comp.run!()` (raises on Throw/Suspend), `Comp.run()` (returns
  raw result). The computation executes, handlers respond to requests, you get
  a result.
- **Stacking handlers** - Reader + State + Writer together. The pipeline reads
  naturally: computation |> handler |> handler |> run.
- **The output option** - `output: fn result, state -> ...` to extract handler
  state alongside the computation result.
- **`defcomp` for named functions** - Defining effectful functions that compose
  naturally.
- **A complete small example** - End-to-end: define a module with a few
  `defcomp` functions, install handlers, run, see the result. Then run the same
  code with different handlers and see a different result.

*Concrete code throughout. Every example is runnable.*

## Layer 4: Syntax In Depth

**Goal:** The reader understands all the syntax the `comp` macro provides and
can write non-trivial computations confidently.

- **The `<-` bind** - Pattern matching on the left, computation on the right.
  What happens when the pattern doesn't match (MatchFailed throw).
- **The `else` clause** - Handling match failures, analogous to `with/else`.
  How unhandled failures propagate.
- **The `catch` clause** - Two forms:
  - **Interception**: `{Module, pattern} -> body` - intercept and handle
    Throw/Yield values locally.
  - **Installation**: `Module -> config` - install a handler for the body.
  - Clause grouping (consecutive same-module clauses merge).
  - Combining interception and installation.
- **Combining `else` and `catch`** - Semantic ordering: `catch(else(body))`.
- **Auto-lifting details** - Where it applies (final expression, `if` without
  `else`, etc.), where it doesn't, and why.
- **`defcomp` and `defcompp`** - Public and private effectful function
  definitions, with `else` and `catch` support.

## Layer 5: Foundational Effects

**Goal:** The reader knows the core effects, when to reach for each one, and
how to use them. These effects solve familiar problems (state, config, errors,
IO, persistence) with better testability and separation of concerns.

Each effect section follows the pattern:
1. The problem it solves (1-2 sentences)
2. Basic usage
3. Handler installation and options
4. Testing patterns (test handler, stubs)
5. Advanced usage / gotchas

### 5a: State & Environment

- **State** - Mutable state within a computation. Tagged instances for multiple
  independent states.
- **Reader** - Immutable environment / config. Tagged instances.
- **Writer** - Append-only log / accumulator. `tell`, `listen`. Tagged
  instances.
- **Scoped state transforms** - The `output` and `suspend` options. How they
  compose across handler layers.

### 5b: Error Handling & Resources

- **Throw** - Typed errors, `catch` interception, `try_catch` for
  `{:ok, v}/{:error, e}` style, the `IThrowable` protocol for domain error
  types.
- **Bracket** - Resource acquisition and guaranteed cleanup (`bracket`,
  `finally`). Relationship to scoped handlers.
- **Debugging** - Stacktraces through CPS, Elixir exception interop
  (`raise`/`throw`/`exit` inside `comp`).

### 5c: Value Generation

- **Fresh** - UUID generation. Production (UUID7) and test (deterministic
  UUID5) handlers.
- **Random** - Random values. Production, seeded, and fixed-sequence handlers.

### 5d: Collections

- **FxList** - Effectful map/iteration with full effect support.
- **FxFasterList** - Faster variant with limited Yield/Suspend support.
  When to choose which.

### 5e: Concurrency (Familiar Patterns)

- **Parallel** - Fork-join: `all`, `race`, `map`. Sequential test handler.
- **AtomicState** - Thread-safe state via Agent. CAS operations. Test handler.
- **AsyncComputation** - Bridge from effectful to non-effectful contexts
  (e.g. LiveView). `start`/`resume`/`cancel`.

### 5f: Persistence & Data

- **DB** - Ecto-backed writes. Insert/update/delete, bulk operations,
  transactions. Three handler types (Ecto, Noop, Test).
- **Command** - Dispatch mutation structs through a handler. The Decider
  pattern.
- **EventAccumulator** - Accumulate domain events via Writer pattern.

### 5g: External Integration

- **Port** - Low-level dispatch to external code. Resolver types. Test stubs.
- **Port.Contract** - Typed contracts via `defport`. Consumer/Provider
  behaviours. Bang variants. Dialyzer support.
- **Port.Provider** - Bridge plain Elixir into effectful implementations.
  Hexagonal architecture's inbound side.

## Layer 6: Advanced Effects

**Goal:** The reader understands what becomes possible when effects can control
execution flow. These effects build on cooperative fibers and continuations
to enable patterns that aren't achievable with standard BEAM concurrency.

This layer should open with an honest framing: the foundational effects
stand alone. The reader doesn't need fibers, channels, or serializable
coroutines to benefit from Skuld. But if they've run into the limitations of
Task/GenStage for complex data pipelines, or wished they could serialize a
running computation, or hit N+1 query problems that DataLoader doesn't quite
solve - this is where Skuld does things nothing else in the BEAM ecosystem
can.

### 6a: Yield (Coroutines)

- **Yield** - Suspend/resume (coroutines). `yield`, `collect`,
  `run_with_driver`.
- **Yield.respond** - Handling yields internally within a computation.
- **Catch clause with Yield** - Intercepting yields via `{Yield, pattern}`.

### 6b: Cooperative Fibers & Concurrency

- **Why fibers?** - What BEAM processes are great at (isolation, fault
  tolerance) and what they're less great at (fine-grained cooperation,
  batching IO across concurrent computations, shared effectful context).
- **FiberPool** - Cooperative fibers with IO batching. The foundation for
  query batching.
- **Channel** - Bounded channels with backpressure. `put_async`/`take_async`.
- **Brook** - High-level streaming. `from_enum`, `map`, `filter`, `to_list`.
  Comparison with GenStage/Flow.

### 6c: Query & Batching

- **The N+1 problem** - Motivation with concrete examples.
- **The `query` macro** - Compile-time dependency analysis, automatic
  concurrent batching.
- **`deffetch` contracts** - Typed DSL for query operations. Executors,
  wiring, bang variants.
- **Query.Cache** - Cross-batch caching, deduplication, scope/lifetime.
- **Port.Contract vs Query.Contract** - When to use which.

### 6d: Serializable Coroutines

- **EffectLogger** - Log, replay, cold-resume lifecycle. Serialization to
  JSON. Loop marking and pruning. Comparison with Temporal.io.

## Layer 7: Patterns & Recipes

**Goal:** The reader can solve real-world problems by combining effects. Each
recipe is a self-contained how-to guide.

### Foundational Recipes

- **Testing effectful code** - The pattern: write domain logic with effects,
  swap handlers for tests. Property-based testing with `stream_data`.
- **Hexagonal architecture** - Structuring an app with Port.Contract
  (outbound), Port.Provider (inbound), and effect-based domain logic.
- **The Decider pattern** - Command + EventAccumulator for event-sourced
  domain logic.
- **Nested / composed handler stacks** - Production vs test handler stacks,
  parameterised by mode.

### Advanced Recipes

- **LiveView integration** - Using AsyncComputation for multi-step wizards
  and long-running operations.
- **Durable workflows** - EffectLogger for persist-and-resume patterns.
  Looping conversations (e.g. LLM chat loops).
- **Data pipelines** - Brook for streaming with backpressure. Channel for
  ordered concurrent processing.
- **Batch data loading** - Query contracts and FiberPool for N+1-free data
  access.

## Layer 8: How It Works (Internals)

**Goal:** The reader understands Skuld's implementation well enough to debug
surprising behaviour, write custom effects, or contribute.

This is essentially the `gory_details.org` material, restructured to follow
the progressive-disclosure narrative rather than being a standalone document.

- **Computations as functions** - The `(env, k) -> {result, env}` type. Why
  functions instead of data structures (vs Freer monads).
- **The environment** - `evidence`, `state`, `leave_scope`,
  `transform_suspend`. What each field does.
- **`bind` and sequencing** - The monadic core. How the `comp` macro expands.
- **Handler dispatch** - `Comp.effect/2`, handler function signature, evidence
  lookup.
- **Scoped handlers** - `Comp.scoped/2`, dual cleanup paths (normal
  continuation vs `leave_scope` chain), reverse-order guarantee.
- **Control effects and CPS** - Why CPS is necessary. How Throw discards,
  Yield captures, and Catch wraps the continuation.
- **The ISentinel protocol** - How `Comp.run` finalises results. Normal values,
  Suspend, Throw.
- **Suspend decoration** - `transform_suspend`, composition across handler
  layers.
- **Writing a custom effect** - Step-by-step guide: signature, operations,
  handler, scoping, test handler.

## Layer 9: Reference

**Goal:** Complete, searchable, no-narrative reference material.

- **API reference** - Generated from `@doc` / `@moduledoc` via ExDoc. Not
  hand-written. Ensure module docs are thorough.
- **Effect quick-reference table** - One row per effect: module, operations,
  handler options, test handler, common patterns. Split into foundational
  and advanced tiers. (The table in the current README is a good start.)
- **Glossary** - computation, effect, handler, evidence, continuation, bind,
  sentinel, suspend, resume, scope, leave_scope.
- **Comparison with alternatives** - Freyja, Haskell effect systems,
  Temporal.io, GenStage/Flow, Mox/Mimic. What Skuld does differently and why.

---

## Notes on Existing Material

How existing docs map to this outline:

| Existing doc                      | Target layer(s) | Notes                                        |
|-----------------------------------|------------------|----------------------------------------------|
| README.md                         | README, 9        | Rewrite; table moves to L9                   |
| gory_details.org                  | 8                | Restructure, don't rewrite from scratch      |
| docs/syntax.md                    | 3, 4             | Split: basics to L3, depth to L4             |
| docs/effects-state-environment.md | 5a               | Fits naturally                               |
| docs/effects-control-flow.md      | 4, 5b, 6a       | Split: syntax to L4, Throw to L5, Yield to L6|
| docs/effects-value-generation.md  | 5c               | Fits naturally                               |
| docs/effects-collections.md       | 5d               | Fits naturally                               |
| docs/effects-concurrency.md       | 5e, 6b          | Split: Parallel/Atomic/Async to L5, rest to L6|
| docs/effects-persistence.md       | 5f               | Fits naturally                               |
| docs/effects-port.md              | 5g               | Fits naturally                               |
| docs/query.md                     | 6c               | Moves to advanced tier                       |
| docs/effect-logger.md             | 6d, 7            | Split: reference to L6, recipes to L7        |
| docs/testing.md                   | 7                | Expand into a full recipe                    |
| docs/architecture.md              | 8                | Merge into internals                         |
| docs/performance.md               | 8, 9             | Benchmarks to L8; summary table to L9        |
| docs/debugging.md                 | 5b               | Merge with Throw/error handling              |

## What Needs Writing From Scratch

- **README** - Rewrite to serve as Layer 0 (hook + install + quick example +
  signposting). The current README mixes too many concerns.
- **Layer 1 (Why)** - No existing material covers the problem space without
  jumping to the solution.
- **Layer 2 (What)** - The conceptual introduction to algebraic effects.
  `gory_details.org` has some of this but at implementation depth.
- **Layer 6 intro** - The "why fibers?" framing that positions advanced effects
  honestly. Needs to acknowledge BEAM process orthodoxy and explain what
  fibers add without being dismissive or defensive.
- **Layer 7 (Patterns & Recipes)** - Most recipes don't exist as standalone
  how-to guides. `testing.md` and `effect-logger.md` have fragments.
- **Layer 9 (Glossary, comparison table)** - Doesn't exist.
