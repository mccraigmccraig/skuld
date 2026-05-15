# Fresh & Random

<!-- nav:header:start -->
[< Throw & Bracket](throw-bracket.md) | [Up: Foundational Effects](state-reader-writer.md) | [Index](../../README.md) | [FxList >](fxlist.md)
<!-- nav:header:end -->

Deterministic value generation for IDs and randomness.

## Fresh

Unique identifier generation:

```elixir
id <- Fresh.fresh_uuid()           # generate a UUID
```

Handlers:

```elixir
# Production: UUID7 (time-ordered, unique)
computation |> Fresh.with_uuid7_handler()

# Test: deterministic UUID5 from a namespace + counter
computation |> Fresh.with_test_handler()
```

## Random

Pure random number generation:

```elixir
n <- Random.random()               # 0.0–1.0 float
n <- Random.random_int(1, 100)     # integer in range
x <- Random.random_element(list)   # random element
shuffled <- Random.shuffle(list)   # Fisher-Yates
```

Handlers:

```elixir
# Production: system :rand
computation |> Random.with_handler()

# Test: fixed seed (deterministic sequence)
computation |> Random.with_seed_handler(seed: 42)

# Test: fixed values in order
computation |> Random.with_fixed_handler(values: [0.5, 0.2, 0.9])
```

| Effect | Production handler | Test handler |
|--------|-------------------|--------------|
| Fresh | `Fresh.with_uuid7_handler()` | `Fresh.with_test_handler()` |
| Random | `Random.with_handler()` | `Random.with_seed_handler(seed: N)` or `Random.with_fixed_handler(values: [...])` |

<!-- nav:footer:start -->

---

[< Throw & Bracket](throw-bracket.md) | [Up: Foundational Effects](state-reader-writer.md) | [Index](../../README.md) | [FxList >](fxlist.md)
<!-- nav:footer:end -->
