# Value Generation

<!-- nav:header:start -->
[< Error Handling & Resources](error-handling.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [Collections >](collections.md)
<!-- nav:header:end -->

The Fresh and Random effects replace non-deterministic operations (UUID
generation, random values) with effects that can be made deterministic
in tests.

## Fresh

Generate UUIDs with swappable handlers for production and testing.

### Production handler

```elixir
comp do
  uuid1 <- Fresh.fresh_uuid()
  uuid2 <- Fresh.fresh_uuid()
  {uuid1, uuid2}
end
|> Fresh.with_uuid7_handler()
|> Comp.run!()
#=> {"01945a3b-...", "01945a3b-..."}  # time-ordered UUIDv7
```

UUIDv7 is time-ordered, making it suitable for database primary keys.

### Test handler

```elixir
namespace = Uniq.UUID.uuid4()

comp do
  uuid <- Fresh.fresh_uuid()
  uuid
end
|> Fresh.with_test_handler(namespace: namespace)
|> Comp.run!()
#=> "550e8400-..."  # deterministic UUIDv5, same every time
```

The test handler generates deterministic UUIDv5 values from a namespace.
Same namespace always produces the same sequence - ideal for assertions
and property-based testing.

### Operations

- `Fresh.fresh_uuid()` - generate a UUID

## Random

Generate random values with three handler modes.

### Production handler

```elixir
comp do
  f <- Random.random()              # float in [0, 1)
  i <- Random.random_int(1, 100)    # integer in range
  elem <- Random.random_element([:a, :b, :c])
  shuffled <- Random.shuffle([1, 2, 3, 4])
  {f, i, elem, shuffled}
end
|> Random.with_handler()
|> Comp.run!()
#=> {0.723..., 42, :b, [3, 1, 4, 2]}
```

### Seeded handler (reproducible)

```elixir
comp do
  a <- Random.random()
  b <- Random.random_int(1, 10)
  {a, b}
end
|> Random.with_seed_handler(seed: {42, 123, 456})
|> Comp.run!()
#=> {0.234..., 7}  # same result every time with this seed
```

### Fixed-sequence handler (specific scenarios)

```elixir
comp do
  a <- Random.random()
  b <- Random.random()
  {a, b}
end
|> Random.with_fixed_handler(values: [0.0, 1.0])
|> Comp.run!()
#=> {0.0, 1.0}  # cycles when exhausted
```

The fixed handler is useful when you need exact values for testing edge
cases (e.g., testing behaviour at probability boundaries).

### Operations

- `Random.random()` - float in `[0, 1)`
- `Random.random_int(min, max)` - integer in range
- `Random.random_element(list)` - random element from list
- `Random.shuffle(list)` - shuffle a list

<!-- nav:footer:start -->

---

[< Error Handling & Resources](error-handling.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [Collections >](collections.md)
<!-- nav:footer:end -->
