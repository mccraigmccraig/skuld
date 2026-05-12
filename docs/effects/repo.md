# Repo

<!-- nav:header:start -->
[< Query & Batching](query-batching.md) | [Index](../../README.md) | [Transactions >](transactions.md)
<!-- nav:header:end -->

Skuld ships with a built-in Ecto Repo contract providing 30+ operations
— `insert`, `update`, `delete`, `get`, `get_by`, `all`, `aggregate`,
`preload`, and more. The same Repo calls run against real Ecto in
production and pure in-memory handlers in tests.

## Architecture

The Repo uses Skuld's Port effect for dispatch. `Skuld.Repo` is a Port
facade bound to `Skuld.Repo.Effectful`:

```elixir
# Under the hood: Repo operations dispatch via Port
Repo.insert(changeset)
# => Port.request(Skuld.Repo.Effectful, :insert, [changeset])
```

This means the Repo plugs into the same Port handler registry as any
other Port contract.

## Production: Ecto adapter

Generate an Ecto adapter with one line:

```elixir
defmodule MyApp.Repo.Port do
  use Skuld.Repo.Ecto, repo: MyApp.Repo
end
```

Install it in the Port handler registry:

```elixir
my_comp
|> Port.with_handler(%{Skuld.Repo.Effectful => MyApp.Repo.Port})
|> Comp.run!()
```

## Testing: InMemory (recommended)

`Repo.InMemory` is a closed-world stateful in-memory store. It wraps
`DoubleDown.Repo.InMemory` and provides read-after-write consistency for
PK-based lookups:

```elixir
alias Skuld.Repo

# Basic — writes and PK reads work without fallback
comp do
  {:ok, user} <- Repo.insert(User.changeset(%{name: "Alice"}))
  found <- Repo.get(User, user.id)
  {user, found}
end
|> Repo.InMemory.with_handler(Repo.InMemory.new())
|> Comp.run!()

# Seed initial state
state = Repo.InMemory.new(seed: [
  %User{id: 1, name: "Alice"},
  %User{id: 2, name: "Bob"}
])

# With fallback for non-PK reads
state = Repo.InMemory.new(
  seed: [%User{id: 1, name: "Alice"}],
  fallback_fn: fn
    :all, [User], state ->
      Map.get(state, User, %{}) |> Map.values()
    :get_by, [User, [name: name]], state ->
      Map.get(state, User, %{})
      |> Map.values()
      |> Enum.find(&(&1.name == name))
  end
)

result =
  Repo.all(User)
  |> Repo.InMemory.with_handler(state)
  |> Comp.run!()

assert length(result) == 1
```

Inspect the final store:

```elixir
{result, store} =
  comp do
    _ <- Repo.insert(User.changeset(%{name: "Charlie"}))
    Repo.get(User, 1)
  end
  |> Repo.InMemory.with_handler(Repo.InMemory.new(),
    output: fn result, state -> {result, state.handler_state} end
  )
  |> Comp.run!()

# store = %{User => %{1 => %User{...}}}
```

### Authoritative operations (bare schema queryables)

| Category | Operations | Behaviour |
|----------|-----------|-----------|
| **Writes** | `insert`, `update`, `delete`, bang variants | Store in state |
| **PK reads** | `get`, `get!` | `nil`/raise on miss (no fallback) |
| **Clause reads** | `get_by`, `get_by!` | Scan and filter |
| **Collection** | `all`, `one`/`one!`, `exists?` | Scan state |
| **Aggregates** | `aggregate` | Compute from state |
| **Bulk** | `insert_all`, `preload`, `reload` | State-backed |

## Testing: Stub (lightweight)

`Repo.Stub` is a stateless handler. Writes apply changesets and return
`{:ok, struct}` but store nothing. Reads go through an optional
`fallback_fn` or raise a clear error:

```elixir
alias Skuld.Repo

# Writes only — reads will raise
comp
|> Port.with_handler(%{Skuld.Repo.Effectful => Repo.Stub.new()})
|> Comp.run!()

# With fallback for reads
comp
|> Port.with_handler(%{
  Skuld.Repo.Effectful => Repo.Stub.new(
    fallback_fn: fn
      :get, [User, 1] -> %User{id: 1, name: "Alice"}
      :all, [User] -> [%User{id: 1, name: "Alice"}]
    end
  )
})
|> Comp.run!()
```

## Testing: OpenInMemory

`Repo.OpenInMemory` is an open-world variant — authoritative for PK reads
only. Everything else falls through to a `fallback_fn`:

```elixir
state = Repo.OpenInMemory.new(
  seed: [%User{id: 1, name: "Alice"}],
  fallback_fn: fn
    :all, [User], _state -> []
    :get_by, [User, [name: "Bob"]], _state -> %User{id: 2, name: "Bob"}
  end
)

comp
|> Repo.OpenInMemory.with_handler(state)
|> Comp.run!()
```

## When to use which

| Handler | Writes stored? | PK reads auto? | Other reads | Best for |
|---------|---------------|----------------|-------------|----------|
| `Repo.Ecto` | Yes (database) | Yes (database) | Yes (database) | Production |
| `Repo.InMemory` | Yes (in memory) | Yes (in memory) | `fallback_fn` | Unit tests with read-after-write |
| `Repo.OpenInMemory` | Yes (in memory) | Yes (in memory) | `fallback_fn` (required) | Tests needing partial store authority |
| `Repo.Stub` | No | No | `fallback_fn` or raise | Fire-and-forget writes |

<!-- nav:footer:start -->

---

[< Query & Batching](query-batching.md) | [Index](../../README.md) | [Transactions >](transactions.md)
<!-- nav:footer:end -->
