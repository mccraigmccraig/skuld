# Durable Computation

<!-- nav:header:start -->
[< SerializableCoroutine](../../../../docs/effects/serializable-coroutine.md) | [Index](../../../../docs/effects/effectlogger.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Pause a computation mid-flight, save its entire execution history as
JSON, and resume it later — after a process restart, on a different
machine, whenever. Every effect invocation is recorded in a serialisable
log. Resume replays the log so the computation continues exactly where
it left off.

## Why not just use Oban jobs?

You can build stateful workflows with Oban jobs, GenServers, or
database-persisted state — encoding the current step as job args or
process state. These approaches work and are battle-tested.

SerializableCoroutine is a different tradeoff. Instead of encoding
state machine transitions as job arguments or `handle_info` clauses,
you write them almost like normal Elixir code. The effect log captures
the execution history automatically, so you don't manually track which
branch was taken, how many loop iterations ran, or what API responses
were received. This matters most when the workflow is non-linear:

- **Branching.** The path taken depends on runtime data. "Step 3" could
  mean "get shipping address" for one order and "confirm payment" for
  another — you'd need to encode the branch decision in job state.
- **Looping.** A retry loop means the same logical step executes multiple
  times. The state-machine encoding already handles iteration — but the
  encoding itself is harder to follow than reading code flow.
- **Side effects between yields.** If the computation calls APIs or
  mutates state between user interactions, you can accumulate results in
  a Map (like `Ecto.Multi`). But the logic spreads across job modules,
  variable bindings become harder to trace, and function-wrapper
  boilerplate adds noise.

The SerializableCoroutine approach lets you read the workflow from top
to bottom — branches, loops, and side effects inline — without
cross-referencing job modules to reconstruct the flow.

## The state machine

An order checkout flow. It fetches customer and cart data from services,
branches on cart contents, loops on payment validation, and records
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
    _ <- State.put(Checkout.State, %{customer: customer, cart: cart, total: total})

    # Yield for user confirmation — shows the cart
    :ok <- Yield.yield(:confirm_order)

    # Branch on cart contents: physical items need a shipping address
    shipping <-
      if has_physical_items?(cart) do
        Yield.yield(:get_shipping_address)
      else
        :skip
      end

    # Payment method with retry loop
    payment <- get_valid_payment()

    # Process payment via external service
    {:ok, receipt} <- Orders.process_payment(cart, payment, shipping)

    # Record audit entry
    order_ctx <- State.get(Checkout.State)
    _ <- Writer.tell({:order_completed, order_ctx, receipt})

    {:ok, receipt}
  end

  defp get_valid_payment do
    comp do
      _ <- EffectLogger.mark_loop(:payment_retry)
      %{total: total} <- State.get(Checkout.State)
      method <- Yield.yield({:get_payment_method, total})

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
    |> State.with_handler(%{}, tag: Checkout.State)
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

This is the key difference from storing state manually. The log records
*what the APIs returned* and *what State contained*. On cold resume
(from serialised JSON), the system replays these entries rather than
re-executing them, rebuilding the closures and variable bindings from the
original computation — so the computation sees the same customer, the same
cart, and the same cart contents that triggered the shipping-address
branch. On hot resume (a live suspended fiber), no replay is needed —
the computation state is still held in a closure and continues
immediately.

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

The branch was taken because `has_physical_items?` was `true` — the log
replayed `State.put` with the original cart data, so the cart contents
were restored and the `if` took the same path. No step tracking needed.

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
loop, payment processing. The intermediate steps use hot resume
(`run/2` with the live suspended fiber — the closure is still available,
no replay needed). The final step shows cold resume from persisted JSON:

```elixir
# Hot resume: the fiber is still live in memory
suspended3 = SerializableCoroutine.run(suspended2, "123 Main St")

# Payment (first attempt fails, loops)
%ExternalSuspended{value: {:get_payment_method, 142.50}} = suspended4 =
  SerializableCoroutine.run(suspended3, %{type: :card, number: "bad"})

# Payment retry
suspended5 = SerializableCoroutine.run(suspended4, %{type: :card, number: "4111..."})

# Cold resume: after serialisation and process restart
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

[< SerializableCoroutine](../../../../docs/effects/serializable-coroutine.md) | [Index](../../../../docs/effects/effectlogger.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
