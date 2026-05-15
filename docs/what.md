# How Effects Work

<!-- nav:header:start -->
[< Why Effects?](why.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Getting Started >](getting-started.md)
<!-- nav:header:end -->

Skuld lets you write code that *describes* side effects without performing
them. Handlers decide what those descriptions mean. The same effectful
code runs with real I/O in production and pure in-memory implementations
in tests.

## The core idea

In a normal Elixir function, `Repo.get(User, id)` hits the database
immediately. The side effect happens at the call site.

In Skuld, `Repo.get(User, id)` returns a **computation** — a value that
describes "I want to get a user by id." It doesn't hit the database. It
just records the intent.

```elixir
comp do
  user <- Repo.get(User, "123")     # returns a computation, no DB call
  updated <- Repo.update(changeset) # another computation, no DB call
  updated                           # final value auto-lifted
end
```

Nothing happens until you run the computation with handlers:

```elixir
# Production: real database (Ecto adapter registered via Port)
computation |> Port.with_handler(%{Skuld.Repo.Effectful => MyApp.Repo.Ecto}) |> Comp.run!()

# Test: in-memory map, same computation
computation |> Repo.InMemory.with_handler(Repo.InMemory.new()) |> Comp.run!()
```

## Three concepts

### 1. Computations describe what to do

A computation is a function `(env, k) -> {result, env}`. It receives an
environment (carrying handlers) and a continuation (what to do next with
the result). When you write `x <- Repo.get(User, id)`, the `<-` operator
chains the computation: "run this, then pass the result to the next
step."

Computations compose. A `comp do` block is just syntax sugar over
`Comp.bind/2` — each `<-` feeds the result of one effect into the next.

### 2. Handlers decide how to do it

A handler interprets effect requests. When a computation says "give me
a user," the handler retrieves it — from a database, an in-memory map,
or a static stub. The computation doesn't know which.

Handlers are installed by piping the computation through
`with_handler`:

```elixir
computation
|> State.with_handler(0)
|> Reader.with_handler(%{env: :prod})
|> Throw.with_handler()
|> Comp.run!()
```

Each handler manages one effect. They compose naturally — the `State`
handler manages a counter, the `Reader` handler provides config, the
`Throw` handler catches errors.

### 3. The same code, different handlers

This is the fundamental property. Write your business logic once:

```elixir
defcomp register(params) do
  config <- Reader.ask()
  id <- Fresh.fresh_uuid()
  {:ok, user} <- Repo.insert(changeset(params, id, config))
  user
end
```

Run it with production handlers (real database, real UUIDs, real config):

```elixir
register(params)
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_uuid7_handler()
|> Port.with_handler(%{Skuld.Repo.Effectful => MyApp.Repo.Ecto})
|> Throw.with_handler()
|> Comp.run!()
```

Run the same code with test handlers (in-memory store, deterministic
UUIDs, test config):

```elixir
register(params)
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_test_handler()
|> Repo.InMemory.with_handler(Repo.InMemory.new())
|> Throw.with_handler()
|> Comp.run!()
```

## Because effects are data

Unlike mocks or DI, Skuld effects are first-class values the runtime
can inspect and manipulate. This enables capabilities that go beyond
handler-swapping:

**Automatic query batching.** The query system can analyze effect
dependencies in a `query do` block and batch independent database
fetches together — eliminating N+1 queries without restructuring
code.

**Cooperative concurrency.** The FiberPool scheduler can interleave
multiple computations, suspending and resuming them at yield points.
Channels provide backpressure. Brook provides effectful streaming.

**Durable workflows.** Because computations can suspend (via `Yield`)
and their effect history can be serialized (via `EffectLogger`), you
can pause a multi-step workflow, persist its state, and resume it
later — across restarts.

## Where to go from here

- [Getting Started](getting-started.md) — write your first computation
- [Foundational Effects](effects/state-reader-writer.md) — State, Reader, Writer, and more
- [Coroutines & Concurrency](effects/yield.md) — Yield, Coroutine, FiberPool
- [Boundaries](effects/port.md) — Port, Repo, hexagonal architecture

<!-- nav:footer:start -->

---

[< Why Effects?](why.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Getting Started >](getting-started.md)
<!-- nav:footer:end -->
