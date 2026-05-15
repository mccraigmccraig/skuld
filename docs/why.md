# Why Effects?

Most Elixir applications follow good practices: separate your data
structures from your persistence layer, push side effects to the edges,
keep business logic pure. This works well — until it doesn't.

This page is about where those practices run out, and what lies beyond
them.

## What we already do well

### Functional core, imperative shell

Push side effects to the boundaries of your system, keep the interior
pure. Extract calculations, validations, and data transformations into
modules with no dependencies on databases, HTTP clients, or external
services.

```elixir
# Pure — takes data, returns data
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

## Where these patterns run out

Between the pure core and the imperative shell sits a layer that doesn't
fit neatly into either: **domain orchestration**.

### The orchestration layer

Consider a typical business operation — processing a subscription renewal:

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

The pure calculations — pricing rules, validation logic, state machines —
are typically straightforward. The hard part is the orchestration: the
code with the most business rules, the most edge cases, and the most
bugs. And that's exactly the code that's hardest to test, because it's
wired to infrastructure.

### The testing problem

To test `renew_subscription/1` you need a database, a payment provider,
and a mailer. You can mock these with Mox or Mimic. For simple cases this
works. But as complexity grows:

- **Stateful call chains get awkward.** When later calls depend on data
  from earlier calls (insert a record, then read it back), each stub
  must return values consistent with what earlier stubs returned.
- **Property-based testing requires ad-hoc implementations.** You can
  use Agents or closures to build stateful test doubles, but you're
  hand-rolling an in-memory implementation for each test.

### The coupling problem

The orchestration code is tangled with infrastructure choices. `Repo.get!`
couples you to Ecto and your specific database. `PaymentProvider.charge`
couples you to a specific payment API. Swapping any of these requires
changing domain code — the very code that encodes your business rules.

### Config helps, but doesn't compose

`Application.get_env` works for one or two dependencies. But it has
sharp edges:

- **Global state.** One test's config change can leak into another
  running concurrently.
- **No scoping.** You can't say "use the test repo only for this
  computation."
- **Config can't change control flow.** What if you want to retry a
  failed payment, suspend and resume later, or batch database reads?
  A config map can swap an implementation, but it can't alter *when*
  or *how often* code runs.

### The determinism problem

Some side effects are subtle. Code that generates UUIDs, reads the
system clock, or calls `:rand` is non-deterministic. A test that passes
99% of the time is worse than one that fails reliably — you can't
reproduce the conditions that caused the failure.

## What would ideal look like?

Imagine the orchestration code were **pure**: no database calls, no HTTP
requests, no randomness — just a description of what should happen, in
what order, with what error handling. The same function that processes a
real payment in production could run against an in-memory map in tests.
You could generate hundreds of random scenarios and verify invariants,
because there's nothing non-deterministic to stub out.

The pure functional core would expand to include the orchestration layer.
The imperative shell would shrink to just the implementations that
actually perform I/O.

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

This is what effects provide. And because effects are first-class
data, the same representation that makes testing deterministic also
enables automatic query batching, cooperative concurrency, and
serialisable workflows that can pause and resume across restarts.
The mechanism that replaces mocks in tests is the same one that
eliminates N+1 queries in production.
