# What Are Algebraic Effects?

<!-- nav:header:start -->
[< Why Effects?](why.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Getting Started >](getting-started.md)
<!-- nav:header:end -->

The [previous section](why.md) identified the problem: domain
orchestration code is full of business logic but can't be pure because it
depends on databases, external services, and other side effects. The
functional-core boundary is drawn in the wrong place - orchestration is
forced into the imperative shell.

Algebraic effects move that boundary. They let you write orchestration
code that *describes* side effects without *performing* them, keeping the
code pure and testable while still expressing everything it needs to.

## Effects as requests

The key idea is simple: instead of *doing* a side effect, you *request*
it.

A regular function call performs the effect immediately:

```
fetch_user(42)  -->  hits the database, returns a user
```

An effectful function produces a *description* of what's needed:

```
fetch_user(42)  -->  "I need user 42" (no database hit yet)
```

The effectful function remains pure. It takes inputs and produces a
description. It doesn't know or care whether the description will be
fulfilled by a real database, an in-memory map, or a test stub that
always returns the same user.

## Handlers decide what effects mean

A **handler** interprets effect requests. Different handlers give the
same request different meanings:

- A **production handler** reads from Postgres
- A **test handler** looks up from an in-memory map
- A **logging handler** records every request for later replay

The orchestration code doesn't change. It always says "I need user 42."
What happens in response depends entirely on which handler is installed.

This is similar in spirit to dependency injection, but with important
differences we'll get to shortly.

## Three kinds of code

With effects, your code has three layers instead of two:

| Layer | Description | Example |
|---|---|---|
| **Pure functions** | Take data, return data. No effects. | `Pricing.calculate_total/2` |
| **Effectful functions** | Request effects but don't perform them. Pure. | `renew_subscription/1` using effects |
| **Handlers** | Actually perform IO. The only side-effecting code. | A handler that calls `Repo.get!/2` |

The effectful middle layer is the key insight. Your orchestration code
moves here - it's still pure (no side effects), but it can express
database access, external service calls, error handling, and anything
else it needs.

## Composition

Effects compose naturally. A computation can use multiple effects
simultaneously - state management, database access, error handling, UUID
generation - and each effect is handled independently. You don't need to
thread dependencies through function parameters or configure a DI
container.

Handlers are installed by wrapping the computation:

```
computation
|> with State handler (initial value: 0)
|> with Reader handler (config: %{timeout: 5000})
|> with DB handler (repo: MyApp.Repo)
|> run!
```

Each handler manages its own concern. Adding a new effect to your code
doesn't require changing any existing function signatures - you just use
the effect and install the handler.

This is where effects diverge from dependency injection:

- **No plumbing**: effects are available implicitly within a computation,
  not passed through every function call
- **Composable**: installing five handlers is as clean as installing one
- **Scoped**: handlers are installed for a specific computation and
  automatically cleaned up when it completes
- **Stackable**: multiple handlers for the same effect can be layered
  (e.g., a local error handler inside a global one)

## The payoff

One codebase, multiple interpretations:

**In production**: handlers talk to real databases, real payment
providers, real email services. The orchestration code runs with full IO.

**In tests**: handlers use in-memory maps, deterministic UUIDs, and
fixed random sequences. The same orchestration code runs purely, with no
external dependencies. You can property-test it - generate hundreds of
random scenarios and verify that business invariants always hold.

**For debugging**: a logging handler can record every effect request and
its result. You can replay a sequence of effects to reproduce a bug
deterministically.

The pure functional core expands to include your orchestration layer. The
imperative shell shrinks to just the handler implementations - thin,
swappable adapters that connect your pure logic to the outside world.

## A word about control flow

Most effects are straightforward: the code requests something, the
handler provides it, execution continues. "Give me user 42" / here's the
user / carry on.

But some effects change *what happens next*:

- **Throw** discards the rest of the computation (like raising an
  exception, but within the effect system)
- **Yield** pauses the computation and hands a resume token to the
  caller (coroutines)
- **Catch** intercepts errors from inner computations

These *control effects* are what make algebraic effects more powerful
than dependency injection or simple request/response patterns. They're
also where things get more conceptually demanding.

You don't need control effects to get started. The foundational effects
(state, configuration, database access, external services, error
handling) already solve the testing and coupling problems from the
[previous section](why.md). Control effects unlock additional
capabilities - coroutines, serializable computations, cooperative
concurrency - that are covered in the [advanced effects](advanced/yield.md)
documentation.

## How Skuld implements this

Skuld is an algebraic effects library for Elixir. Its implementation
choices are designed to feel natural in a dynamic language:

- **Single type**: there's one computation type. You don't need to track
  `Maybe (Either Error (State Int a))` in your head. The `comp` macro
  produces computations; computations compose with other computations.
  Auto-lifting means plain values become computations automatically where
  needed.
- **Evidence passing**: handlers are stored in a map (the "evidence"),
  looked up in O(1) when an effect is requested. No searching through
  handler stacks.
- **CPS for control effects**: continuations allow Throw, Yield, and
  Catch to manipulate control flow. This is an implementation detail -
  you don't need to understand CPS to use Skuld.
- **Scoped handlers**: handlers are installed for a specific computation
  and automatically cleaned up, with guaranteed cleanup order.
- **`comp` macro**: provides `do`-notation for sequencing effectful
  operations, with `<-` for binding results, `else` for handling pattern
  match failures, and `catch` for intercepting errors and control flow.

The [Getting Started](getting-started.md) guide walks through writing
your first computation.

<!-- nav:footer:start -->

---

[< Why Effects?](why.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Getting Started >](getting-started.md)
<!-- nav:footer:end -->
