# Property-Based Testing

Algebraic effects enable a powerful testing pattern: **effectful code that runs pure**.
Domain logic written with effects can execute with real database handlers in production
and pure in-memory handlers in tests - enabling property-based testing with thousands
of iterations per second.

## The Pattern

[TodosMcp](https://github.com/mccraigmccraig/skuld/tree/main/todos_mcp) demonstrates
this approach. The domain handlers use effects for all I/O:

```elixir
# Domain logic in Todos.Handlers - uses effects, doesn't perform I/O directly
defcomp handle(%ToggleTodo{id: id}) do
  ctx <- Reader.ask(CommandContext)
  todo <- Repository.get_todo!(ctx.tenant_id, id)  # Port effect
  changeset = Todo.changeset(todo, %{completed: not todo.completed})
  updated <- DB.update(changeset)                   # DB effect
  {:ok, updated}
end
```

The `Run.execute/2` function composes different handler stacks based on mode:

```elixir
# Production: real database
Run.execute(operation, mode: :database, tenant_id: tenant_id)
# -> Port.with_handler(%{Repository => Repository.Ecto})
# -> DB.Ecto.with_handler(Repo)

# Testing: pure in-memory
Run.execute(operation, mode: :in_memory, tenant_id: tenant_id)
# -> Port.with_handler(%{Repository => Repository.InMemory})
# -> InMemoryPersist.with_handler()
```

## Property Tests

With pure handlers, property-based testing becomes trivial. TodosMcp uses standard
`stream_data` with domain-specific generators:

```elixir
# test/todos_mcp/todos/handlers_property_test.exs
use ExUnitProperties

property "ToggleTodo is self-inverse" do
  check all(cmd <- Generators.create_todo(), max_runs: 100) do
    {:ok, original} = create_and_get(cmd)

    {:ok, toggled} = Run.execute(%ToggleTodo{id: original.id}, mode: :in_memory)
    {:ok, restored} = Run.execute(%ToggleTodo{id: original.id}, mode: :in_memory)

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

## Implementing This Pattern

To enable property-based testing in your project:

1. **Structure domain logic with effects** - Use `Port`, `DB`, `Reader`, etc.
   instead of direct Repo calls or process dictionary access.

2. **Create in-memory implementations** - For each effect that touches external state,
   provide a pure alternative. Skuld includes test handlers for common effects:
   - `Port.with_test_handler/2` - Stub responses for external calls
   - `DB.Test.with_handler/2` - Stub persist operations
   - `Fresh.with_test_handler/2` - Deterministic UUID generation

3. **Write domain-specific generators** - Create StreamData generators for your
   command/query structs and domain entities (see `TodosMcp.Generators`).

4. **Compose handler stacks by mode** - A single `Run.execute/2` entry point that
   switches handlers based on `:mode` option keeps tests and production code aligned.

The key insight is that **no special Skuld support is needed** - the existing handler
composition is already sufficient. Generators are domain-specific (your structs,
your entities), so they belong in your application, not in Skuld.
