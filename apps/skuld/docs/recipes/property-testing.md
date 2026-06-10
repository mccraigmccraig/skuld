# Property-Based Testing

<!-- nav:header:start -->
[< Hexagonal Architecture](hexagonal-architecture.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../../../README.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:header:end -->

Effect handlers make deterministic testing the default. Swap production
handlers for pure in-memory ones, and the same computation that hits a
database in production runs against a map in tests.

## Handler-swapping

```elixir
defcomp register(params) do
  config <- Reader.ask()
  id <- Fresh.fresh_uuid()
  {:ok, user} <- Repo.insert(User.changeset(%{id: id, name: params.name, tier: config.default_tier}))
  {:ok, user}
end

# Test — deterministic, no database
register(%{name: "Alice"})
|> Reader.with_handler(%{default_tier: :free})
|> Fresh.with_test_handler()
|> Repo.InMemory.with_handler(Repo.InMemory.new())
|> Throw.with_handler()
|> Comp.run!()
```

`Repo.InMemory` is a closed-world store with read-after-write consistency.
Records inserted during the test are immediately readable by subsequent
`Repo.get` / `Repo.get_by` calls.

## Property-based tests

Because test handlers are deterministic, you can generate hundreds of
random scenarios with `stream_data` and verify invariants:

```elixir
property "user registration is idempotent by email" do
  check all name <- string(:alphanumeric, min_length: 1),
            email <- constant("test@example.com"),
            tier <- member_of([:free, :pro]) do

    result =
      register(%{name: name, email: email})
      |> Reader.with_handler(%{default_tier: tier})
      |> Fresh.with_test_handler()
      |> Repo.InMemory.with_handler(Repo.InMemory.new())
      |> Throw.with_handler()
      |> Comp.run!()

    assert {:ok, _} = result
  end
end
```

## Stateful test doubles

`Port.with_stateful_handler` provides stateful in-memory test doubles
without hand-rolling Agents or ETS tables:

```elixir
handler = fn
  MyRepo, :insert, [record], state ->
    {{:ok, record}, Map.put(state, record.id, record)}

  MyRepo, :get, [id], state ->
    {Map.get(state, id), state}
end

computation
|> Port.with_stateful_handler(%{}, handler)
|> Throw.with_handler()
|> Comp.run!()
```

The state is threaded across Port calls within the scope. Reads see
writes from earlier in the computation — no setup needed.

## Deterministic value generation

| Effect | Test handler |
|--------|-------------|
| Fresh | `Fresh.with_test_handler()` — deterministic UUID5 |
| Random | `Random.with_seed_handler(seed: 42)` or `Random.with_fixed_handler(values: [...])` |
| State | `State.with_handler(initial)` — same handler, just the value |
| Reader | `Reader.with_handler(value)` — same handler, just the config |

<!-- nav:footer:start -->

---

[< Hexagonal Architecture](hexagonal-architecture.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../../../README.md) | [Umbrella →](https://hexdocs.pm/skuld/architecture.html)
<!-- nav:footer:end -->
