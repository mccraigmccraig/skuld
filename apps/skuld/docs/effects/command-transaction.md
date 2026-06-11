# Command & Transaction

<!-- nav:header:start -->
[< Yield](yield.md) | [Up: Foundational Effects](state-reader-writer.md) | [Index](../../README.md) | [Hexagonal Architecture >](../recipes/hexagonal-architecture.md)
<!-- nav:header:end -->

Dispatch and transactional boundaries.

## Command

Fire-and-forget dispatch to a handler function:

```elixir
result <- Command.execute(%CreateTodo{title: "Buy milk"})
```

The handler function receives the command and returns a computation:

```elixir
computation |> Command.with_handler(fn
  %CreateTodo{title: title} ->
    # returns a computation (e.g., insert into repo)
    Repo.insert(%Todo{title: title})
end)
```

## Transaction

Rollback-safe state with nested savepoints:

```elixir
{:ok, result} <- Transaction.transact(inner_comp)
_ <- Transaction.rollback(:validation_failed)
```

`transact` wraps a computation in a savepoint. On error or `rollback`,
all state changes within the transaction are reverted. Nested `transact`
calls create nested savepoints.

Handlers:

```elixir
# In-memory: env state rollback, no database
computation |> Transaction.Noop.with_handler()

# Ecto: wraps in Ecto.Multi transaction
computation |> Transaction.Ecto.with_handler(MyApp.Repo)
```

Place the transaction handler above the effects that participate in
the transaction (State, Port/Repo):

```elixir
computation
|> State.with_handler(0)
|> Port.with_handler(%{...})
|> Transaction.Ecto.with_handler(MyApp.Repo)
|> Throw.with_handler()
|> Comp.run!()
```

| Operation | Purpose |
|-----------|---------|
| `Command.execute(cmd)` | Dispatch command to handler |
| `Transaction.transact(comp)` | Savepoint for state rollback |
| `Transaction.rollback(reason)` | Rollback to last savepoint |
| `Transaction.try_transact(comp)` | Transact without error wrapping |

<!-- nav:footer:start -->

---

[< Yield](yield.md) | [Up: Foundational Effects](state-reader-writer.md) | [Index](../../README.md) | [Hexagonal Architecture >](../recipes/hexagonal-architecture.md)
<!-- nav:footer:end -->
