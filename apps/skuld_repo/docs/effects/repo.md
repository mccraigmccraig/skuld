# Repo

<!-- nav:header:start -->
[< Adapter](adapter.md) | [Up: Boundaries](port.md) | [Index](../../README.md) | [Query System >](query.md)
<!-- nav:header:end -->

Skuld's built-in database contract. Operations dispatch via the Port
effect to pluggable handlers — Ecto in production, in-memory maps in tests.

## Usage

```elixir
{:ok, user} <- Repo.insert(User.changeset(%{name: "Alice"}))
{:ok, user} <- Repo.get(User, id)
{:ok, user} <- Repo.get_by(User, email: "alice@example.com")
{:ok, users} <- Repo.all(User)
{:ok, user} <- Repo.one(from u in User, where: u.age > 18)
{:ok, count} <- Repo.aggregate(User, :count, :id)
```

Bang variants return unwrapped values or throw on error:

```elixir
user <- Repo.insert!(changeset)
user <- Repo.get!(User, id)
```

## Production

Generate an Ecto adapter and register via Port:

```elixir
defmodule MyApp.Repo.Port do
  use Skuld.Repo.Ecto, repo: MyApp.Repo
end

computation
|> Port.with_handler(%{Skuld.Repo.Effectful => MyApp.Repo.Port})
|> Throw.with_handler()
|> Comp.run!()
```

## Test

`Repo.InMemory` — closed-world store with read-after-write consistency:

```elixir
computation |> Repo.InMemory.with_handler(Repo.InMemory.new())
```

Records inserted during the test are immediately readable by subsequent
`Repo.get` / `Repo.get_by` calls — no mocks, no stubs.

`Repo.Stub` — stateless stub. Writes return results but store nothing.
Reads require a fallback function:

```elixir
fallback = fn
  :get, [User, id], _state -> {:ok, %User{id: id}}
end

computation |> Repo.Stub.with_handler(fallback: fallback)
```

## Operations

| Category | Operations |
|----------|-----------|
| Write | `insert/1,2`, `update/1,2`, `delete/1,2`, `insert_all/3`, `insert_or_update/1,2` |
| Read by PK | `get/2,3`, `get!/2,3` |
| Read by fields | `get_by/2,3`, `get_by!/2,3` |
| Query | `all/1,2`, `one/1,2`, `aggregate/4`, `query/1,2,3` |
| Reload/stats | `reload/1,2`, `preload/2,3`, `stream/2,3`, `load/2,3`, `all_by/3` |

Bang variants: `insert!/1,2`, `update!/1,2`, `delete!/1,2`, `get!/2,3`,
`get_by!/2,3`, `one!/1,2`, `query!/1,2,3`.

<!-- nav:footer:start -->

---

[< Adapter](adapter.md) | [Up: Boundaries](port.md) | [Index](../../README.md) | [Query System >](query.md)
<!-- nav:footer:end -->
