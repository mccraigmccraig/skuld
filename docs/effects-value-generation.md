# Effects: Value Generation

## Fresh

Generate fresh UUIDs with two handler modes:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Fresh

# Production: v7 UUIDs (time-ordered, good for database primary keys)
comp do
  uuid1 <- Fresh.fresh_uuid()
  uuid2 <- Fresh.fresh_uuid()
  {uuid1, uuid2}
end
|> Fresh.with_uuid7_handler()
|> Comp.run!()
#=> {"01945a3b-...", "01945a3b-..."}  # time-ordered, unique

# Testing: deterministic v5 UUIDs (reproducible given same namespace)
namespace = Uniq.UUID.uuid4()

comp do
  uuid1 <- Fresh.fresh_uuid()
  uuid2 <- Fresh.fresh_uuid()
  {uuid1, uuid2}
end
|> Fresh.with_test_handler(namespace: namespace)
|> Comp.run!()
#=> {"550e8400-...", "6ba7b810-..."}

# Same namespace always produces same sequence - great for testing!
comp do
  uuid <- Fresh.fresh_uuid()
  uuid
end
|> Fresh.with_test_handler(namespace: namespace)
|> Comp.run!()
#=> "550e8400-..."  # same UUID every time with same namespace
```

## Random

Generate random values with three handler modes:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.Random

# Production: uses Erlang :rand module
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

# Testing: deterministic with seed (reproducible)
comp do
  a <- Random.random()
  b <- Random.random_int(1, 10)
  {a, b}
end
|> Random.with_seed_handler(seed: {42, 123, 456})
|> Comp.run!()
#=> {0.234..., 7}  # same result every time with this seed

# Testing: fixed sequence for specific scenarios
comp do
  a <- Random.random()
  b <- Random.random()
  {a, b}
end
|> Random.with_fixed_handler(values: [0.0, 1.0])
|> Comp.run!()
#=> {0.0, 1.0}  # cycles when exhausted
```
