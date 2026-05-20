# Durable Computation

<!-- nav:header:start -->
[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:header:end -->

Pause a computation mid-flight, save its entire execution history as
JSON, and resume it later — after a process restart, on a different
machine, whenever. Every effect invocation is recorded in a serialisable
log. Resume replays the log so the computation continues exactly where
it left off.

## Why not just store the step number?

If your state machine is linear — step 1, step 2, step 3 — storing
`{step: 2, name: "Alice"}` in a JSON column works fine. Durable
computation earns its keep when the computation *isn't* linear:

- **Branching.** The path taken depends on runtime data. "Step 3" could
  mean "get shipping address" for one order and "confirm payment" for
  another. The step number alone doesn't tell you what to do next.
- **Looping.** A retry loop means the same logical step executes multiple
  times. A step counter can't distinguish "first attempt" from "third
  attempt."
- **Side effects between yields.** If the computation calls APIs or
  mutates state between user interactions, those results are part of the
  execution history. A naive approach would re-execute side effects on
  resume — potentially with different results.

The effect log captures *everything*: which branch was taken, how many
loop iterations ran, and the results of every side effect. Resume
replays the log deterministically, so the computation sees exactly the
same state it had before.

## The state machine

An order checkout flow. It fetches customer and cart data from services,
branches on the order total, loops on payment validation, and records
an audit trail:

```elixir
defmodule Checkout do
  use Skuld.Syntax

  defcomp run do
    # Fetch data from external services
    customer <- Orders.fetch_customer(current_customer_id())
    cart <- Orders.fetch_cart(current_customer_id())
    total = calculate_total(cart)

    # Persist the order context in State
    _ <- State.put(%{customer: customer, cart: cart, total: total})

    # Yield for user confirmation — shows the cart
    :ok <- Yield.yield(:confirm_order)

    # Branch on total: large orders need a shipping address
    shipping <-
      if total > 100 do
        Yield.yield(:get_shipping_address)
      else
        :skip
      end

    # Payment method with retry loop
    payment <- get_valid_payment()

    # Process payment via external service
    {:ok, receipt} <- Orders.process_payment(cart, payment, shipping)

    # Record audit entry
    order_ctx <- State.get()
    _ <- Writer.tell({:order_completed, order_ctx, receipt})

    {:ok, receipt}
  end

  defp get_valid_payment do
    comp do
      _ <- EffectLogger.mark_loop(:payment_retry)
      method <- Yield.yield(:get_payment_method)

      case validate_payment(method) do
        :ok -> method
        {:error, reason} ->
          _ <- Writer.tell({:payment_validation_failed, reason})
          get_valid_payment()
      end
    end
  end
end
```

## Build and run

Wrap the computation with `SerializableCoroutine.new`. `EffectLogger` is
installed innermost automatically — your `handlers_fun` installs the
application-level handlers above it:

```elixir
sc =
  SerializableCoroutine.new(Checkout.run(), fn comp ->
    comp
    |> Port.with_handler(%{
      Orders => Orders.Service,
    })
    |> State.with_handler(%{})
    |> Writer.with_handler([])
    |> Yield.with_handler()
    |> Throw.with_handler()
  end)
```

Run it — it fetches customer and cart (Port calls), stores the context
(State), then suspends at the first yield:

```elixir
%ExternalSuspended{value: :confirm_order} = suspended =
  SerializableCoroutine.run(sc)
```

## Inspecting the log

The log captures every effect up to the suspension point — including the
Port calls that fetched data and the State mutation that stored it:

```elixir
log = SerializableCoroutine.get_log(suspended)
Log.to_list(log)
# => [
#   %EffectLogEntry{sig: Port, data: {:request!, Orders, :fetch_customer, [...]}, value: %Customer{...}, state: :executed},
#   %EffectLogEntry{sig: Port, data: {:request!, Orders, :fetch_cart, [...]}, value: [%CartItem{...}, ...], state: :executed},
#   %EffectLogEntry{sig: State, data: {:put, %{customer: ..., cart: ..., total: 142.50}}, value: :ok, state: :executed},
#   %EffectLogEntry{sig: Yield, data: :confirm_order, value: nil, state: :started}
# ]
```

This is the key difference from storing a step number. The log records
*what the APIs returned* and *what State contained*. On resume, the
system replays these entries rather than re-executing them — so the
computation sees the same customer, the same cart, and the same `total:
142.50` that triggered the shipping-address branch.

## Serialize and persist

```elixir
json = SerializableCoroutine.serialize(log)
# persist json to DB, file, or queue...
```

## Resume

Restore the log from storage and resume. `run/3` accepts the JSON string
directly — the system deserializes it, replays the log to restore state,
and injects the resume value at the suspension point:

```elixir
{:ok, json} = load_from_storage()

%ExternalSuspended{value: :get_shipping_address} = suspended2 =
  SerializableCoroutine.run(json, sc, :confirmed)
```

The branch was taken because `total > 100` was `true` — the log replayed
`State.put` with the original cart data, so `total` was restored to
`142.50` and the `if` took the same path. No step-number tracking needed.

Inspect the updated log — the yield was resolved, and the log shows the
transition:

```elixir
Log.to_list(SerializableCoroutine.get_log(suspended2))
# => [
#   ...  (Port and State entries from before, now all :executed)
#   %EffectLogEntry{sig: Yield, data: :confirm_order, value: :confirmed, state: :executed},
#   %EffectLogEntry{sig: Yield, data: :get_shipping_address, value: nil, state: :started}
# ]
```

Continue through the remaining steps — shipping address, payment retry
loop, payment processing:

```elixir
# Shipping address
suspended3 = SerializableCoroutine.run(suspended2, "123 Main St")

# Payment (first attempt fails, loops)
%ExternalSuspended{value: :get_payment_method} = suspended4 =
  SerializableCoroutine.run(suspended3, %{type: :card, number: "bad"})

# Payment retry
suspended5 = SerializableCoroutine.run(suspended4, %{type: :card, number: "4111..."})

# Complete
{:ok, json} = load_from_storage()
%Coroutine.Completed{result: {{:ok, receipt}, final_log}} =
  SerializableCoroutine.run(json, sc, %{type: :card, number: "4111..."})
```

## Loop marking

The payment retry loop uses `EffectLogger.mark_loop(:payment_retry)` to
keep the log bounded. Without it, every retry iteration accumulates in
the log forever. With `mark_loop`, each new iteration prunes the previous
one — the log only keeps the current iteration:

```elixir
Log.to_list(final_log)
# Only the last payment retry iteration appears —
# earlier attempts with :payment_validation_failed were pruned
```

`mark_loop` works with nested loops too. Inner loop iterations are pruned
without disturbing outer loop boundaries.

| Function | Purpose |
|----------|---------|
| `SerializableCoroutine.new(comp, handlers_fun)` | Build a serialisable coroutine |
| `SerializableCoroutine.get_log(suspended)` | Extract the effect log |
| `SerializableCoroutine.serialize(log)` | Serialize log to JSON |
| `SerializableCoroutine.deserialize(json)` | Restore log from JSON |
| `EffectLogger.mark_loop(atom())` | Mark restart point to prune log |

<!-- nav:footer:start -->

---

[< LiveView Integration](liveview.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [Batch Loading >](batch-loading.md)
<!-- nav:footer:end -->
