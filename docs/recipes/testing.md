# Testing Effectful Code

<!-- nav:header:start -->
[< Serializable Coroutines (EffectLogger)](../advanced/effect-logger.md) | [Index](../../README.md) | [Hexagonal Architecture >](hexagonal-architecture.md)
<!-- nav:header:end -->

Algebraic effects enable a powerful testing pattern: domain logic
written with effects runs with real handlers in production and pure
in-memory handlers in tests. This makes property-based testing with
thousands of iterations per second practical for code that would
normally require a database.

## The pattern

1. Write domain logic with effects (Port, Transaction, Reader, Fresh, etc.)
2. Run production code with real handlers (Ecto, HTTP clients, etc.)
3. Run tests with pure/stub handlers (in-memory maps, deterministic
   values, recorded calls)

No mocks, no process dictionary tricks, no special test infrastructure.
The same code, different handlers.

## Example: a todo app

Domain logic uses effects for all I/O:

```elixir
defmodule Todos.Handlers do
  use Skuld.Syntax

  defcomp handle(%ToggleTodo{id: id}) do
    ctx <- Reader.ask(CommandContext)
    todo <- Repository.get_todo!(ctx.tenant_id, id)
    updated <- Repository.update_todo!(ctx.tenant_id, Todo.changeset(todo, %{completed: not todo.completed}))
    {:ok, updated}
  end
end
```

A single `Run.execute/2` entry point switches handler stacks by mode:

```elixir
defmodule Run do
  def execute(operation, opts) do
    mode = Keyword.get(opts, :mode, :database)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    Todos.Handlers.handle(operation)
    |> with_handlers(mode, tenant_id)
    |> Comp.run!()
  end

  defp with_handlers(comp, :database, tenant_id) do
    comp
    |> Reader.with_handler(%CommandContext{tenant_id: tenant_id}, tag: CommandContext)
    |> Port.with_handler(%{Repository => Repository.Ecto})
    |> Fresh.with_uuid7_handler()
    |> Throw.with_handler()
  end

  defp with_handlers(comp, :in_memory, tenant_id) do
    comp
    |> Reader.with_handler(%CommandContext{tenant_id: tenant_id}, tag: CommandContext)
    |> Port.with_handler(%{Repository => Repository.InMemory})
    |> InMemoryPersist.with_handler()
    |> Fresh.with_test_handler()
    |> Throw.with_handler()
  end
end
```

## Unit tests

Test individual computations by installing the handlers you need:

```elixir
test "toggle marks incomplete todo as complete" do
  todo = %Todo{id: "1", title: "Buy milk", completed: false}

  result =
    Todos.Handlers.handle(%ToggleTodo{id: "1"})
    |> Reader.with_handler(%CommandContext{tenant_id: "t1"}, tag: CommandContext)
    |> Port.with_test_handler(%{
      Repository.key(:get_todo, "t1", "1") => {:ok, todo},
      Repository.key(:update_todo, "t1", _) => {:ok, %Todo{todo | completed: true}}
    })
    |> Throw.with_handler()
    |> Comp.run!()

  assert {:ok, %Todo{completed: true}} = result
end
```

## Property-based tests

With pure handlers, property-based testing becomes straightforward:

```elixir
use ExUnitProperties

property "ToggleTodo is self-inverse" do
  check all(cmd <- Generators.create_todo(), max_runs: 100) do
    {:ok, original} = Run.execute(cmd, mode: :in_memory, tenant_id: "t1")

    {:ok, toggled} = Run.execute(
      %ToggleTodo{id: original.id},
      mode: :in_memory, tenant_id: "t1"
    )
    {:ok, restored} = Run.execute(
      %ToggleTodo{id: original.id},
      mode: :in_memory, tenant_id: "t1"
    )

    assert restored.completed == original.completed
  end
end

property "CompleteAll only affects incomplete todos" do
  check all(todos <- Generators.todos(max_length: 20)) do
    incomplete_count = Enum.count(todos, &(not &1.completed))
    {:ok, result} = run_with_todos(%CompleteAll{}, todos)
    assert result.updated == incomplete_count
  end
end
```

This runs hundreds of iterations per second because there's no database,
no network, no process overhead - just pure function calls.

## Built-in test handlers

Skuld provides test handlers for common effects:

| Effect | Test handler | What it does |
|--------|-------------|--------------|
| Port   | `Port.with_test_handler/2` | Exact-match stub map |
| Port   | `Port.with_fn_handler/2` | Pattern-matching function |
| Port   | `Port.with_stateful_handler/4` | Stateful `fn(mod, name, args, state) -> {result, new_state}` |
| Port   | Any handler + `log: true` | Dispatch logging in `Port.State.log` |
| Port.Repo | `Port.Repo.Test` (effectful resolver) | Stateless Repo (sensible defaults, no state) |
| Port.Repo | `Repo.InMemory.with_handler/3` | Stateful in-memory Repo (read-after-write consistency) |
| Transaction | `Transaction.Noop.with_handler/0` | Env state rollback, no database |
| Fresh  | `Fresh.with_test_handler/0` | Deterministic UUIDs (UUID5) |
| Random | `Random.with_handler/1` | Fixed sequence or seeded |
| State  | (standard handler) | In-memory, no persistence |
| Parallel | `Parallel.with_sequential_handler/0` | Sequential for determinism |
| AtomicState | `AtomicState.with_state_handler/1` | State-backed, no Agent |

## Writing domain-specific generators

Create `StreamData` generators for your domain types:

```elixir
defmodule MyApp.Generators do
  use ExUnitProperties

  def create_todo do
    gen all(
      title <- string(:alphanumeric, min_length: 1, max_length: 100),
      priority <- member_of([:low, :medium, :high])
    ) do
      %CreateTodo{title: title, priority: priority}
    end
  end

  def todos(opts \\ []) do
    max = Keyword.get(opts, :max_length, 10)
    list_of(todo(), max_length: max)
  end

  defp todo do
    gen all(
      id <- string(:alphanumeric, length: 8),
      title <- string(:alphanumeric, min_length: 1),
      completed <- boolean()
    ) do
      %Todo{id: id, title: title, completed: completed}
    end
  end
end
```

## Testing plain hexagons with Mox

When testing plain Elixir code that drives a Port contract (via
`Port.Adapter.Plain` or `Port.Adapter.Effectful`), you can use
[Mox](https://hexdocs.pm/mox) against the contract's generated `Plain`
behaviour for isolated unit tests — no effect machinery needed. This
also strengthens the incremental adoption story: introducing a Port
contract immediately improves test isolation, before any effectful
code is written.

See [Testing plain hexagons with Mox](hexagonal-architecture.md#testing-plain-hexagons-with-mox)
in the Hexagonal Architecture recipe for the full setup, examples, and
adoption path.

## Stateful test handlers

When tests need **read-after-write consistency** — insert a record, then
get it back within the same computation — use `Port.with_stateful_handler`
or the built-in `Repo.InMemory`.

### Port.with_stateful_handler

The primitive for building custom stateful test doubles. The handler
function receives `(mod, name, args, state)` and returns
`{result, new_state}`:

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

Use `output:` to inspect the final handler state:

```elixir
{result, final_state} =
  my_comp
  |> Port.with_stateful_handler(%{}, handler,
    output: fn result, state -> {result, state.handler_state} end
  )
  |> Comp.run!()
```

### Repo.InMemory

A complete in-memory Repo implementation built on
`Port.with_stateful_handler`. State is a `%{{schema, id} => struct}`
map. All standard Repo operations are supported — `insert`, `update`,
`delete`, `get`, `get_by`, `all`, `exists?`, `aggregate`, etc.

```elixir
alias Skuld.Effects.Port.Repo

# Start empty — inserted records get auto-incremented IDs
result =
  comp do
    {:ok, user} <- Repo.insert(User.changeset(%{name: "Alice"}))
    found <- Repo.get(User, user.id)
    {user, found}
  end
  |> Repo.InMemory.with_handler()
  |> Comp.run!()

assert {user, user} = result
```

Seed initial state with `Repo.InMemory.seed/1`:

```elixir
initial = Repo.InMemory.seed([
  %User{id: 1, name: "Alice"},
  %User{id: 2, name: "Bob"}
])

result =
  Repo.all(User)
  |> Repo.InMemory.with_handler(initial)
  |> Comp.run!()

assert length(result) == 2
```

Inspect the final store:

```elixir
{result, store} =
  comp do
    _ <- Repo.insert(User.changeset(%{name: "Alice"}))
    _ <- Repo.insert(User.changeset(%{name: "Bob"}))
    Repo.all(User)
  end
  |> Repo.InMemory.with_handler(%{},
    output: fn result, state -> {result, state.handler_state} end
  )
  |> Comp.run!()

# store is %{{User, 1} => %User{...}, {User, 2} => %User{...}}
```

### When to use Repo.InMemory vs Repo.Test

- **`Repo.Test`** — stateless: writes apply changesets and return
  `{:ok, struct}` but nothing is stored. Reads return defaults
  (`nil`, `[]`, `false`). Use for tests that only need fire-and-forget
  writes with applied changesets.

- **`Repo.InMemory`** — stateful: writes store records, subsequent
  reads find them. Use when your test needs read-after-write consistency
  (insert then get, update then read back, etc.).

## Tips

- **Test at the handler boundary** - test computations with handlers,
  not the effect calls in isolation
- **Use `Port.with_fn_handler`** for property tests where exact values
  aren't known upfront
- **Port test handlers record calls** - use `Port.with_test_handler`
   or `Port.with_fn_handler` to stub persistence operations
- **Mix handler modes** - `with_handler`, `with_test_handler`, and
  `with_fn_handler` all merge into a unified registry. Use runtime
  dispatch for contracts you want to exercise and test stubs for
  contracts you want to isolate:

  ```elixir
  comp
  |> Port.with_test_handler(%{Notifications.key(:send, msg) => :ok})
  |> Port.with_handler(%{Repository => Repo.Test})
  |> Throw.with_handler()
  |> Comp.run!()
  ```

- **Port dispatch logging** captures every Port call as a
  `{mod, name, args, result}` 4-tuple directly in `Port.State.log`.
  Pass `log: true` and `output:` to any Port handler installer — no
  Writer needed:

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

- **Fresh.with_test_handler** produces deterministic UUIDs - tests
  are reproducible
- **Compose handler stacks in one place** - a `Run.execute/2` or
  similar function keeps test and production stacks aligned

<!-- nav:footer:start -->

---

[< Serializable Coroutines (EffectLogger)](../advanced/effect-logger.md) | [Index](../../README.md) | [Hexagonal Architecture >](hexagonal-architecture.md)
<!-- nav:footer:end -->
