# skuld_durable

<!-- nav:header:start -->
[EffectLogger & SerializableCoroutine >](docs/effects/effectlogger.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Durable execution for Skuld — pause-serialize-resume workflows and
effect-level execution logging. Build computations that can survive
process restarts, server reboots, and deployment cycles.

## What's included

- **`Skuld.Effects.EffectLogger`** — intercepts every effect invocation
  across all handlers and records it in a flat, JSON-serializable log.
  Enables three modes: **replay** (short-circuit completed effects),
  **resume** (continue a suspended computation from where it left off),
  and **rerun** (re-execute failed computations). Flat log structure
  preserves ordering even when continuations are discarded by Throw.
- **`Skuld.SerializableCoroutine`** — wraps a coroutine with EffectLogger
  installed innermost. Handles all lifecycle states: fresh start (run
  until first yield), live resume (pass a value to a suspended fiber),
  and cold resume (replay the log, then apply a resume value). `serialize`
  and `deserialize` convert logs to/from JSON for storage.

## Installation

```elixir
def deps do
  [
    {:skuld_durable, "~> 0.32"}
  ]
end
```

## Example: durable order checkout

```elixir
alias Skuld.SerializableCoroutine

sc = SerializableCoroutine.new(CheckoutWizard.run(), fn comp ->
  comp |> State.with_handler(%{cart: []}) |> Yield.with_handler() |> Throw.with_handler()
end)

# Start — runs until the first Yield
suspended = SerializableCoroutine.run(sc)

# Persist to your database
json = SerializableCoroutine.serialize(SerializableCoroutine.get_log(suspended))
MyApp.Repo.insert_checkout_state(user_id, json)

# --- Server restarts ---

# Deserialize and cold-resume from where we left off
{:ok, log} = SerializableCoroutine.deserialize(json)
SerializableCoroutine.run(log, sc, {:add_item, %{sku: "B-42"}})
```

## Further reading

- [EffectLogger](https://hexdocs.pm/skuld_durable/effectlogger.html) — flat log architecture, replay/resume/rerun
- [SerializableCoroutine](https://hexdocs.pm/skuld_durable/serializable-coroutine.html) — lifecycle and dispatch modes
- [Durable Computation recipe](https://hexdocs.pm/skuld/durable-computation.html) — full workflow with branching, loops, and audit trails

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[EffectLogger & SerializableCoroutine >](docs/effects/effectlogger.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
