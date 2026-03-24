# Testing Effectful Code

Algebraic effects enable a powerful testing pattern: domain logic
written with effects runs with real handlers in production and pure
in-memory handlers in tests. This makes property-based testing with
thousands of iterations per second practical for code that would
normally require a database.

## The pattern

1. Write domain logic with effects (Port, DB, Reader, Fresh, etc.)
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
    changeset = Todo.changeset(todo, %{completed: not todo.completed})
    updated <- DB.update(changeset)
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
    |> DB.Ecto.with_handler(MyApp.Repo)
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
      Repository.key(:get_todo, "t1", "1") => {:ok, todo}
    })
    |> DB.Test.with_handler(fn
      %DB.Update{input: cs} -> Ecto.Changeset.apply_changes(cs)
    end)
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
| Port   | `Port.with_test_handler/1` | Exact-match stub map |
| Port   | `Port.with_fn_handler/1` | Pattern-matching function |
| DB     | `DB.Test.with_handler/1` | Records ops, returns stubs |
| DB     | `DB.Noop.with_handler/0` | Transactions only, raises on writes |
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

## Tips

- **Test at the handler boundary** - test computations with handlers,
  not the effect calls in isolation
- **Use `Port.with_fn_handler`** for property tests where exact values
  aren't known upfront
- **DB.Test records calls** - assert on the `calls` list to verify
  operations happened in the right order
- **Fresh.with_test_handler** produces deterministic UUIDs - tests
  are reproducible
- **Compose handler stacks in one place** - a `Run.execute/2` or
  similar function keeps test and production stacks aligned
