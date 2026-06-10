# skuld_durable

<!-- nav:header:start -->
[EffectLogger & SerializableCoroutine >](docs/effects/effectlogger.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Durable execution for Skuld: pause-serialize-resume workflows and effect logging.

## What's included

- **`Skuld.SerializableCoroutine`** — pause-serialize-resume for durable workflows
- **`Skuld.Effects.EffectLogger`** — execution logging with replay, resume, and rerun

## Installation

```elixir
def deps do
  [
    {:skuld_durable, "~> 0.32"}
  ]
end
```

## Quick start

```elixir
alias Skuld.SerializableCoroutine

sc = SerializableCoroutine.new(MyWizard.run(), fn comp ->
  comp |> State.with_handler(%{}) |> Yield.with_handler() |> Throw.with_handler()
end)

# Fresh start — suspends at first yield
suspended = SerializableCoroutine.run(sc)

# Serialize and persist
json = SerializableCoroutine.serialize(SerializableCoroutine.get_log(suspended))

# Later: cold resume from serialised state
SerializableCoroutine.run(json, sc, resume_value)
```

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[EffectLogger & SerializableCoroutine >](docs/effects/effectlogger.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
