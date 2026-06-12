# Skuld

<!-- nav:header:start -->
[Why Effects? >](https://hexdocs.pm/skuld/why.html)
<!-- nav:header:end -->

[![Test](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml/badge.svg)](https://github.com/mccraigmccraig/skuld/actions/workflows/test.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/skuld.svg)](https://hex.pm/packages/skuld)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/skuld/)

An effect system for Elixir: write pure business logic which emits effect
description data, provide handlers which implement effects. The pattern is
simple and very powerful. Distributed across seven independently-versioned
packages:

| Package | Provides |
|---|---|
| [`skuld`](https://hex.pm/packages/skuld) | Core engine (`Comp`), syntax (`Syntax`), foundational effects |
| [`skuld_concurrency`](https://hex.pm/packages/skuld_concurrency) | Coroutines, `FiberPool`, `Channel`/`Brook` streaming, `AsyncCoroutine` |
| [`skuld_port`](https://hex.pm/packages/skuld_port) | `Port` dispatch, `EffectfulFacade`, `Adapter` |
| [`skuld_durable`](https://hex.pm/packages/skuld_durable) | `SerializableCoroutine`, `EffectLogger` for durable workflows |
| [`skuld_query`](https://hex.pm/packages/skuld_query) | Auto-batching data fetches via `Query` do-notation (Haxl-style) |
| [`skuld_repo`](https://hex.pm/packages/skuld_repo) | Ecto Repo integration (`InMemory`, `Ecto`, `Stub`) |
| [`skuld_process`](https://hex.pm/packages/skuld_process) | `Parallel` fan-out, `AtomicState` for process-level state |

See the [package architecture](https://hexdocs.pm/skuld/architecture.html) for a detailed breakdown of how these fit together.

## The old problem

Between pure business logic and side-effecting infrastructure
sits the orchestration layer — "fetch the user, check permissions, load
their subscription, hit some APIs, compute a price, write an invoice."
This code encodes your most important business rules, but it's tangled with
databases, APIs, and randomness — making it hard to test, hard to
refactor, and often — impossible to property-test.

## Another way

Skuld lets you write *pure* orchestration code that *describes* side effects
without performing them — then handlers decide what those descriptions mean.
The exact same "effectful" code runs with side-effecting handlers in production
and pure in-memory handlers in tests — fully deterministic, fully pure, and
straightforwardly property-testable.

## The effect advantage

Effectful computations condense domain logic to its essence. Handlers
provide context — production vs test, concurrency, batching — without
touching the computation. Effects are first-class data: inspect them,
serialise them, replay them.

Under the hood, the `comp` macro transforms sequential-looking code
into nested `Comp.bind` calls — there's no magic, just functions
calling functions:

```elixir
comp do
  x <- Reader.ask()
  y <- State.get()
  x + y
end

# Expands to:
Comp.bind(Reader.ask(), fn x ->
  Comp.bind(State.get(), fn y ->
    Comp.pure(x + y)
  end)
end)
```

Each `<-` becomes a `bind` call, each bound variable becomes a
continuation parameter. Every expression that looks side-effecting
is just a function constructing another function. [Read the full
internals →](https://hexdocs.pm/skuld/internals.html)

### Composability

Effects compose with zero ceremony. This query function reads like
straightforward sequential code, but when it runs, concurrency
happens at two levels: within the `defquery` block (`fetch_user`
and `fetch_orders` run together via dependency analysis), and
across all streamed invocations — `Brook.map` runs 4 transforms
concurrently, and `FiberPool` batches their `deffetch` calls into
single round-trips:

```elixir
defquery build_account_summary(user_id, month) do
  user <- AccountQueries.fetch_user(user_id)
  orders <- AccountQueries.fetch_orders(user_id, month)
  details <- Query.map(Enum.map(orders, & &1.id), &AccountQueries.fetch_order_details/1)
  build_account_summary(user, orders, details)
end

# Feed a stream of users through — 4 concurrent transforms, all deffetch
# calls batched together by FiberPool
comp do
  source <- Brook.from_enum(user_ids)
  summaries <- Brook.map(source, &build_account_summary(&1, "2026-01"), concurrency: 4)
  Brook.to_list(summaries)
end
|> Skuld.Query.with_executor(AccountQueries, AccountExecutor)
|> Channel.with_handler()
|> FiberPool.with_handler()
|> Comp.run!()
```

`build_account_summary` knows nothing about batch sizes, concurrency limits,
database round-trips, or the other account summaries which also need to be
built - it's pure domain logic. Everything else is handler
wiring — swappable, testable, composable.

[Full batch loading recipe →](https://hexdocs.pm/skuld/recipes/batch-loading.html)

### Suspension & resumption

A pausable computation that implements a state machine as normal
code. Branching is just `if` — no state enum or dispatch table.
Every `<-` pattern-match is a validation gate and the `else` clause
catches unhappy paths at any step:

```elixir
defmodule LoanApp do
  use Skuld.Syntax

  alias Skuld.Effects.Yield

  @threshold 100_000

  defcomp apply do
    {:ok,
     %{
       employment: employment,
       income: income,
       employer_id: employer_id
     }} <- Yield.yield(:personal_info)

    {:ok, _} <- if employment == :self_employed do
      verify_business(employer_id)
    else
      verify_employer(employer_id)
    end

    {:ok, _} <- if income > @threshold do
      Yield.yield(:additional_verification)
    else
      {:ok, :skip}
    end

    {:ok, decision} <- Yield.yield(:review_and_submit)
    Underwriter.decide(employment, income)
  else
    other -> other
  end

  defcomp verify_business(employer_id) do
    {:ok, _} <- Yield.yield(:business_verification)
    do_verify_business(employer_id)
  else
    other -> other
  end
end
```

Run it from a LiveView with `AsyncCoroutine`:

```elixir
# mount
{:ok, runner} = AsyncCoroutine.run(LoanApp.apply(), tag: :loan)

# handle_info — the state machine pauses at each yield
def handle_info({AsyncCoroutine, :loan, %ExternalSuspend{value: :personal_info}}, socket) do
  personal = Accounts.get_personal_info(socket.assigns.user_id)
  AsyncCoroutine.run(socket.assigns.runner, {:ok, personal})
  {:noreply, socket}
end

# Only reached for self-employed applicants
def handle_info({AsyncCoroutine, :loan, %ExternalSuspend{value: :business_verification}}, socket) do
  docs = socket.assigns.business_docs_form |> to_business_docs()
  AsyncCoroutine.run(socket.assigns.runner, {:ok, docs})
  {:noreply, socket}
end

def handle_info({AsyncCoroutine, :loan, {:ok, decision}}, socket) do
  {:noreply, assign(socket, decision: decision, step: :done)}
end
```

Test it — two paths through the same computation, deterministic,
no processes, no stubs:

```elixir
comp =
  LoanApp.apply()
  |> Yield.with_handler()
  |> Throw.with_handler()

# Self-employed, high income — all 4 yields
fiber = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
fiber = Coroutine.run(fiber, {:ok, %{employment: :self_employed,
                                      income: 200_000, employer_id: nil}})
fiber = Coroutine.run(fiber, {:ok, %{license: "LIC-123"}})
fiber = Coroutine.run(fiber, {:ok, %{verified: true}})
%Coroutine.Completed{result: {:ok, _}} = Coroutine.run(fiber, {:ok, :submitted})

# Employed, low income — skips business and additional verification
fiber2 = comp |> Coroutine.new(Env.new()) |> Coroutine.run()
fiber2 = Coroutine.run(fiber2, {:ok, %{employment: :employed,
                                        income: 50_000, employer_id: "ACME"}})
%Coroutine.Completed{result: {:ok, _}} = Coroutine.run(fiber2, {:ok, :submitted})
```

An event-decomposed state machine would encode every unique path
as dispatch state — `employment` branches, `income` branches,
interaction between them. Here the branches are just `if` in the
code. Same computation, same handlers, same testability.

[Full LiveView integration recipe →](https://hexdocs.pm/skuld/recipes/liveview.html)

## Installation

Start with the core package:

```elixir
def deps do
  [
    {:skuld, "~> 0.32"}
  ]
end
```

Add sibling packages as you need their capabilities:

```elixir
{:skuld_concurrency, "~> 0.32"},   # coroutines, streaming
{:skuld_port, "~> 0.32"},          # Port/adapter boundaries
{:skuld_durable, "~> 0.32"},       # durable workflows
{:skuld_query, "~> 0.32"},         # query batching
{:skuld_repo, "~> 0.32"},          # Ecto integration
{:skuld_process, "~> 0.32"},       # parallel execution
```

Each package is independently versioned. Check the latest versions on the
[skuld hex.pm page](https://hex.pm/packages/skuld).

## Where next?

| If you want to... | Read |
|---|---|
| Understand the problem effects solve | [Why Effects?](https://hexdocs.pm/skuld/why.html) |
| See how effects and handlers work | [How It Works](https://hexdocs.pm/skuld/what.html) |
| Write your first computation | [Getting Started](https://hexdocs.pm/skuld/getting-started.html) |
| State, Reader, Writer, Throw, Fresh, Random | [Foundational Effects](https://hexdocs.pm/skuld/effects/state-reader-writer.html) |
| Understand the package architecture | [Package Architecture](https://hexdocs.pm/skuld/architecture.html) |
| Yield, Coroutines, FiberPool, Channels, Async | [Coroutines & Concurrency](https://hexdocs.pm/skuld/effects/yield.html) |
| Port, Repo, Hexagonal Architecture | [Boundaries](https://hexdocs.pm/skuld/effects/port.html) |
| Eliminate N+1 queries | [Batch Loading](https://hexdocs.pm/skuld/recipes/batch-loading.html) |
| Handler-swapping for deterministic testing | [Property Testing](https://hexdocs.pm/skuld/recipes/property-testing.html) |
| Full effect and API reference | [Reference](https://hexdocs.pm/skuld/reference.html) |
| Peek under the hood — CPS, evidence-passing, custom effects | [How It Really Works](https://hexdocs.pm/skuld/internals.html) |

## License

MIT License — see [LICENSE](LICENSE) for details.

<!-- nav:footer:start -->

---

[Why Effects? >](https://hexdocs.pm/skuld/why.html)
<!-- nav:footer:end -->
