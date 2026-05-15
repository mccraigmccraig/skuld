# Getting Started

Add `skuld` to your dependencies:

```elixir
def deps do
  [{:skuld, "~> 0.27"}]
end
```

## Your first computation

A computation describes what should happen. Write it with `comp do`:

```elixir
defmodule MyApp.Examples do
  use Skuld.Syntax

  defcomp greet(name) do
    trimmed = String.trim(name)
    if trimmed == "" do
      {:error, :empty_name}
    else
      {:ok, "Hello, #{trimmed}!"}
    end
  end
end
```

Run it with `Comp.run!()`:

```elixir
iex> MyApp.Examples.greet("Alice") |> Comp.run!()
{:ok, "Hello, Alice!"}
```

The `defcomp` macro defines a function that returns a computation (a
2-arity function). `Comp.run!()` executes it. If the computation
produces a sentinel (an error or suspension), `run!` raises.

For more control, use `Comp.run()` which returns `{result, env}`:

```elixir
iex> {result, _env} = MyApp.Examples.greet("Alice") |> Comp.run()
iex> result
{:ok, "Hello, Alice!"}
```

## Adding effects

Effects let your computation describe side effects without performing
them. Here's one that generates IDs and reads configuration:

```elixir
defcomp register(params) do
  config <- Reader.ask()           # read configuration
  id <- Fresh.fresh_uuid()         # generate a unique ID
  {:ok, %{id: id, name: params.name, tier: config.default_tier}}
end
```

To run it, install handlers for each effect:

```elixir
register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_uuid7_handler()
|> Comp.run!()
# => {:ok, %{id: "018f9b8c-...", name: "Alice", tier: :free}}
```

## Production vs test

The same computation runs with different handlers:

```elixir
alias Skuld.Repo

defcomp register(params) do
  config <- Reader.ask()
  id <- Fresh.fresh_uuid()
  {:ok, user} <- Repo.insert(User.changeset(%{id: id, name: params.name, tier: config.default_tier}))
  {:ok, user}
end

# Production
register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_uuid7_handler()
|> Port.with_handler(%{Skuld.Repo.Effectful => MyApp.Repo.Ecto})
|> Throw.with_handler()
|> Comp.run!()

# Test — same code, deterministic, no database
register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_test_handler()
|> Repo.InMemory.with_handler(Repo.InMemory.new())
|> Throw.with_handler()
|> Comp.run!()
```

`Repo.InMemory` is a closed-world in-memory store. Records inserted
during the test are immediately readable by subsequent `Repo.get` /
`Repo.get_by` calls — no mocks, no stubs.

## What next?

- [How Effects Work](what.md) — the conceptual model
- [State, Reader & Writer](effects/state-reader-writer.md) — foundational effects
- [Port](effects/port.md) — dispatching to external implementations
- [Repo](effects/repo.md) — built-in database contract
