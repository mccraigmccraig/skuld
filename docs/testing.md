# Testing

<!-- nav:header:start -->
[< Syntax Guide](syntax.md) | [Up: Core Concepts](what.md) | [Index](../README.md) | [Query & Batching >](../advanced/query-batching.md)
<!-- nav:header:end -->

Handler-swappable determinism is Skuld's primary value proposition, not
an afterthought. Because domain logic requests effects rather than
performing them, you can swap every handler — databases become in-memory
maps, UUIDs become deterministic sequences, randomness becomes seeded —
without changing the code under test.

## The pattern

1. Write domain logic with effects
2. Run in production with real handlers (Ecto, HTTP, UUIDv7)
3. Run in tests with pure handlers (in-memory maps, deterministic values)

No mocks, no process dictionary tricks, no special test infrastructure.
The same code, different handlers.

## A single entry point

A `Run.execute/2` function switches handler stacks by mode, keeping
production and test stacks aligned:

```elixir
defmodule Run do
  def execute(operation, opts) do
    mode = Keyword.get(opts, :mode, :production)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    Todos.Handlers.handle(operation)
    |> with_handlers(mode, tenant_id)
    |> Comp.run!()
  end

  defp with_handlers(comp, :production, tenant_id) do
    comp
    |> Reader.with_handler(%CommandContext{tenant_id: tenant_id}, tag: CommandContext)
    |> Port.with_handler(%{Skuld.Repo.Effectful => MyApp.Repo.Ecto})
    |> Fresh.with_uuid7_handler()
    |> Throw.with_handler()
  end

  defp with_handlers(comp, :test, tenant_id) do
    comp
    |> Reader.with_handler(%CommandContext{tenant_id: tenant_id}, tag: CommandContext)
    |> Port.with_handler(%{Skuld.Repo.Effectful => Repo.Stub.new()})
    |> Fresh.with_test_handler()
    |> Throw.with_handler()
  end
end
```

## Unit tests with Port stubs

Test individual computations by installing the handlers you need.
Port's test stubs give you exact-match dispatch:

```elixir
test "toggle marks incomplete todo as complete" do
  todo = %Todo{id: "1", title: "Buy milk", completed: false}

  result =
    Todos.Handlers.handle(%ToggleTodo{id: "1"})
    |> Reader.with_handler(%CommandContext{tenant_id: "t1"}, tag: CommandContext)
    |> Port.with_test_handler(%{
      Repository.__key__(:get_todo, "t1", "1") => {:ok, todo},
      Repository.__key__(:update_todo, "t1", _) => {:ok, %Todo{todo | completed: true}}
    })
    |> Throw.with_handler()
    |> Comp.run!()

  assert {:ok, %Todo{completed: true}} = result
end
```

## Property-based tests

With pure handlers, property-based testing runs hundreds of iterations
per second — no database, no network, just pure function calls:

```elixir
use ExUnitProperties

property "ToggleTodo is self-inverse" do
  check all(cmd <- Generators.create_todo(), max_runs: 100) do
    {:ok, original} = Run.execute(cmd, mode: :test, tenant_id: "t1")

    {:ok, toggled} = Run.execute(
      %ToggleTodo{id: original.id},
      mode: :test, tenant_id: "t1"
    )
    {:ok, restored} = Run.execute(
      %ToggleTodo{id: original.id},
      mode: :test, tenant_id: "t1"
    )

    assert restored.completed == original.completed
  end
end
```

## Built-in test handlers

Every effect has a deterministic test handler:

| Effect | Test handler | What it does |
|--------|-------------|--------------|
| Fresh | `Fresh.with_test_handler/1` | Deterministic UUIDs (UUID5) |
| Random | `Random.with_seed_handler/1` | Seeded random via ExUnit seed |
| Random | `Random.with_fixed_handler/2` | Fixed sequence of values |
| State | (standard handler) | In-memory, no persistence |
| Writer | `Writer.with_handler` with `:output` | Accumulate and inspect log |
| Throw | `Throw.with_handler/1` | Catch and inspect thrown errors |
| Parallel | `Parallel.with_sequential_handler/1` | Sequential execution for determinism |
| AtomicState | `AtomicState.with_state_handler/3` | State-backed, no Agent process |
| Transaction | `Transaction.Noop.with_handler/1` | Env state rollback, no database |
| Transaction | `Transaction.Ecto.with_handler/2` | Real Ecto transaction (integration tests) |
| Port | `Port.with_test_handler/3` | Exact-match stub map |
| Port | `Port.with_fn_handler/3` | Pattern-matching function |
| Port | `Port.with_stateful_handler/4` | Stateful `fn(mod, name, args, state)` |
| Skuld.Repo | `Repo.Stub.new/1` | Stateless — writes apply changesets, reads use fallback |
| Skuld.Repo | `Repo.InMemory.with_handler/3` | Stateful — PK read-after-write consistency |

## Stateful test handlers

When tests need **read-after-write consistency** — insert a record, then
get it back within the same computation.

### Port.with_stateful_handler

The primitive for building custom stateful doubles. The handler receives
`(mod, name, args, state)` and returns `{result, new_state}`:

```elixir
handler = fn
  MyCache, :put, [key, value], state ->
    {:ok, Map.put(state, key, value)}

  MyCache, :get, [key], state ->
    {Map.get(state, key), state}
end

result =
  my_comp
  |> Port.with_stateful_handler(%{}, handler)
  |> Comp.run!()
```

Inspect final state with `:output`:

```elixir
{result, final_state} =
  my_comp
  |> Port.with_stateful_handler(%{}, handler,
    output: fn result, state -> {result, state.handler_state} end
  )
  |> Comp.run!()
```

### Repo.Stub

A stateless Repo handler. Write operations apply changesets and return
`{:ok, struct}`. All reads go through an optional `fallback_fn`, or raise
a clear error — the stub never silently returns `nil` or `[]`:

```elixir
alias Skuld.Repo

# Writes only — reads will raise:
comp
|> Port.with_handler(%{Skuld.Repo.Effectful => Repo.Stub.new()})
|> Throw.with_handler()
|> Comp.run!()

# With fallback for reads:
comp
|> Port.with_handler(%{
  Skuld.Repo.Effectful => Repo.Stub.new(
    fallback_fn: fn
      :get, [User, 1] -> %User{id: 1, name: "Alice"}
      :all, [User] -> [%User{id: 1, name: "Alice"}]
    end
  )
})
|> Throw.with_handler()
|> Comp.run!()
```

### Repo.InMemory

A stateful in-memory Repo implementation. State is a
`%{Schema => %{pk => struct}}` map. Writes go to the store. PK-based
reads (`get`, `get!`) check state first — if found, returned directly;
if not, fall through to `fallback_fn` or raise. Other reads always go
through `fallback_fn` or raise:

```elixir
alias Skuld.Repo

result =
  comp do
    {:ok, user} <- Repo.insert(User.changeset(%{name: "Alice"}))
    found <- Repo.get(User, user.id)
    {user, found}
  end
  |> Repo.InMemory.with_handler(Repo.InMemory.new())
  |> Comp.run!()

assert {user, user} = result
```

Seed initial state with a fallback for non-PK reads:

```elixir
state = Repo.InMemory.new(
  seed: [%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}],
  fallback_fn: fn
    :all, [User], state ->
      Map.get(state, User, %{}) |> Map.values()
  end
)

result =
  Repo.all(User)
  |> Repo.InMemory.with_handler(state)
  |> Comp.run!()

assert length(result) == 2
```

Inspect the final store:

```elixir
{result, store} =
  comp do
    _ <- Repo.insert(User.changeset(%{name: "Alice"}))
    _ <- Repo.insert(User.changeset(%{name: "Bob"}))
    Repo.get(User, 1)
  end
  |> Repo.InMemory.with_handler(Repo.InMemory.new(),
    output: fn result, state -> {result, state.handler_state} end
  )
  |> Comp.run!()
```

### When to use which

- **`Repo.Stub`** — stateless. Writes apply changesets but store nothing.
  All reads require a `fallback_fn` or raise. Use for fire-and-forget
  writes, or full control over read return values.
- **`Repo.InMemory`** — stateful. Writes store records, PK reads find
  them automatically. Use when your test needs read-after-write
  consistency (insert then get, update then read back).

## Port dispatch logging

Capture every Port call with `log: true`:

```elixir
{result, log} =
  comp
  |> Port.with_test_handler(stubs,
    log: true,
    output: fn r, state -> {r, state.log} end
  )
  |> Throw.with_handler()
  |> Comp.run!()

# log is [{mod, name, args, result}, ...] in chronological order
```

## Tips

- **Test at the handler boundary** — test computations with handlers, not
  effects in isolation
- **Compose handler stacks in one place** — a `Run.execute/2` function
  keeps test and production stacks aligned
- **Use `Port.with_fn_handler`** for property tests where exact values
  aren't known upfront
- **`Fresh.with_test_handler`** produces deterministic UUIDs
- **Mix handler modes** — `with_handler`, `with_test_handler`, and
  `with_fn_handler` merge into a unified Port registry:

  ```elixir
  comp
  |> Port.with_test_handler(%{Notifications.__key__(:send, msg) => :ok})
  |> Port.with_handler(%{Skuld.Repo.Effectful => Repo.Stub.new()})
  |> Throw.with_handler()
  |> Comp.run!()
  ```

<!-- nav:footer:start -->

---

[< Syntax Guide](syntax.md) | [Up: Core Concepts](what.md) | [Index](../README.md) | [Query & Batching >](../advanced/query-batching.md)
<!-- nav:footer:end -->
