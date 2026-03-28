# Why Effects?

<!-- nav:header:start -->
[< Skuld](../README.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [What Are Algebraic Effects? >](what.md)
<!-- nav:header:end -->

Most Elixir applications follow good practices: separate your data
structures from your persistence layer, push side effects to the edges,
keep business logic pure. This works well - until it doesn't.

This page is about where those practices run out, and what lies beyond
them.

## What we already do well

### Functional core, imperative shell

The well-known pattern (Gary Bernhardt, 2012): push side effects to the
boundaries of your system, keep the interior pure. Extract calculations,
validations, and data transformations into modules with no dependencies
on databases, HTTP clients, or external services.

```elixir
# Pure - takes data, returns data
defmodule Pricing do
  def calculate_total(line_items, tax_rate) do
    subtotal = Enum.sum(Enum.map(line_items, & &1.price * &1.quantity))
    tax = Decimal.mult(subtotal, tax_rate)
    Decimal.add(subtotal, tax)
  end
end
```

This is good practice. Nothing in this document argues against it. If a
function can be pure, it should be pure.

### Layered architecture

Phoenix contexts, domain services, Ecto schemas. The standard layered
architecture separates data representation from persistence from web
concerns. Each layer has a clear responsibility:

- **Schemas** define data structures
- **Contexts** provide the public API for a domain
- **Controllers / LiveViews** handle HTTP and UI concerns

### Extracting pure functions

The advice is familiar: extract pure functions wherever you can. Pricing
rules, validation logic, data transformations, state machines - if it
takes data and returns data, keep it that way. These functions are trivial
to test, easy to reason about, and compose naturally.

## Where these patterns run out

Between the pure core and the imperative shell sits a layer that doesn't
fit neatly into either: **domain orchestration**.

### The orchestration layer

Consider a typical business operation - processing a subscription renewal:

```elixir
def renew_subscription(user_id) do
  user = Repo.get!(User, user_id)
  subscription = Repo.get_by!(Subscription, user_id: user.id, active: true)
  plan = Repo.get!(Plan, subscription.plan_id)

  # Pure calculation
  price = Pricing.calculate_renewal(plan, subscription)

  case PaymentProvider.charge(user.payment_method, price) do
    {:ok, charge} ->
      {:ok, new_sub} =
        subscription
        |> Subscription.renew_changeset(charge)
        |> Repo.update()

      Mailer.send_renewal_confirmation(user, new_sub)
      {:ok, new_sub}

    {:error, :card_declined} ->
      subscription
      |> Subscription.mark_payment_failed()
      |> Repo.update()

      Mailer.send_payment_failed(user)
      {:error, :payment_failed}
  end
end
```

This function encodes real business logic: the sequence of operations,
what happens when payment fails, when to send which email. It's domain
knowledge, not infrastructure plumbing. But it can't live in the
functional core because it needs the database, the payment provider,
and the mailer at every step.

The `Pricing.calculate_renewal/2` call is pure. Everything around it
is not.

### This is where most of the interesting code lives

The pure calculations - pricing rules, validation logic, state machines -
are typically straightforward. The hard part is the orchestration: the
code with the most business rules, the most edge cases, and the most
bugs. And that's exactly the code that's hardest to test, because it's
wired to infrastructure.

### The testing problem

To test `renew_subscription/1` you need:

- A database with users, subscriptions, and plans
- A payment provider (or a mock of one)
- A mailer (or a mock of one)

You can mock these with Mox or Mimic. For simple cases — a few stubs
per test — this works well. But as orchestration complexity grows:

- **Stateful call chains get awkward.** When later calls depend on data
  from earlier calls (insert a record, then read it back), each stub
  must return values consistent with what earlier stubs returned.
  Adding a new data access call means updating every test's stub setup.
- **Property-based testing requires ad-hoc in-memory implementations.**
  You can generate random inputs and use Agents or closures to build
  stateful test doubles, but you're hand-rolling an in-memory
  implementation for each test that needs one — there's no reusable
  abstraction.

### The coupling problem

The orchestration code is tangled with infrastructure choices:

- `Repo.get!` couples you to Ecto and your specific database
- `PaymentProvider.charge` couples you to a specific payment API
- `Mailer.send_renewal_confirmation` couples you to a specific email service

Swapping any of these requires changing domain code - the very code that
encodes your business rules. In theory, you could use behaviours and
dependency injection. In practice:

### Dependency injection helps, but doesn't compose

You could restructure the code to accept injected dependencies:

```elixir
def renew_subscription(user_id, opts \\ []) do
  repo = Keyword.get(opts, :repo, Repo)
  payment = Keyword.get(opts, :payment, PaymentProvider)
  mailer = Keyword.get(opts, :mailer, Mailer)
  # ...
end
```

This works for one or two dependencies. But real orchestration code
touches many services, and the plumbing becomes unwieldy:

- Every function signature grows with each new dependency
- Passing dependencies through multiple layers of function calls is
  tedious and error-prone
- Dependencies don't compose - there's no clean way to say "use these
  five test doubles together" without threading them everywhere
- DI can swap *implementations*, but it can't change *control flow* -
  what if you want to retry a failed payment? suspend the operation and
  resume it later? batch database reads across concurrent operations?

### The determinism problem

Some side effects are subtle. Code that generates UUIDs, reads the
system clock, or calls `:rand` is non-deterministic. A test that passes
99% of the time and fails on leap-day edge cases is worse than one that
fails reliably, because you can't reproduce the conditions that caused
the failure.

## What would ideal look like?

Imagine the orchestration code were **pure**: no database calls, no HTTP
requests, no randomness - just a description of what should happen, in
what order, with what error handling. The same function that processes a
real payment in production could run against an in-memory map in tests.
You could generate hundreds of random scenarios and verify invariants,
because there's nothing non-deterministic to stub out.

The pure functional core would expand to include the orchestration layer.
The imperative shell would shrink to just the implementations that
actually perform IO.

```
Traditional:               With effects:

+------------------+       +------------------+
| Imperative Shell |       | Handlers (IO)    |  <-- thin, swappable
| (orchestration,  |       +------------------+
|  IO, everything  |       | Effectful Core   |  <-- pure orchestration
|  that isn't a    |       | (business logic,  |
|  pure calc)      |       |  error handling,  |
+------------------+       |  sequencing)      |
| Functional Core  |       +------------------+
| (pure calcs)     |       | Functional Core  |  <-- same as before
+------------------+       | (pure calcs)     |
                           +------------------+
```

This is what algebraic effects provide. The [next section](what.md)
explains how.

<!-- nav:footer:start -->

---

[< Skuld](../README.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [What Are Algebraic Effects? >](what.md)
<!-- nav:footer:end -->
