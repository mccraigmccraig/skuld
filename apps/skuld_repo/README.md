# skuld_repo

<!-- nav:header:start -->
[Repo >](docs/effects/repo.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Ecto Repo integration for Skuld: effectful dispatch facade with InMemory, Ecto, and Stub handlers.

## What's included

- **`Skuld.Repo`** — effectful dispatch facade using `EffectfulFacade`
- **`Skuld.Repo.Effectful`** — effectful contract for standard Ecto Repo operations
- **`Skuld.Repo.Ecto`** — production handler wrapping a real Ecto Repo
- **`Skuld.Repo.InMemory`** — closed-world in-memory store for tests
- **`Skuld.Repo.OpenInMemory`** — open-world in-memory store for tests
- **`Skuld.Repo.Stub`** — stateless stub for unit tests

## Installation

```elixir
def deps do
  [
    {:skuld_repo, "~> 0.32"}
  ]
end
```

## Quick start

```elixir
alias Skuld.Repo

comp do
  user <- Repo.insert!(changeset)
  found <- Repo.get(User, user.id)
  {user, found}
end
|> Port.with_handler(%{Repo.Effectful => MyApp.Repo.Ecto})
|> Throw.with_handler()
|> Comp.run!()
```

See the [architecture guide](https://hexdocs.pm/skuld/architecture.html) for how this fits into the Skuld ecosystem.

<!-- nav:footer:start -->

---

[Repo >](docs/effects/repo.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
