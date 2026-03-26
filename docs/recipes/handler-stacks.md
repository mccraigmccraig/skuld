# Handler Stacks

<!-- nav:header:start -->
[< The Decider Pattern](decider-pattern.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [LiveView Integration >](liveview.md)
<!-- nav:header:end -->

Handler stacks are the composition point where you wire effects to
implementations. A well-structured stack makes it easy to switch
between production, test, and development configurations.

## The basics

Handlers are installed by piping a computation through `with_handler`
functions. Each handler registers itself in the environment's evidence
map by its effect signature. When an effect operation executes, it
looks up its handler by key - there is no concept of one handler
"seeing" effects before another. Order generally doesn't matter.

```elixir
my_computation
|> State.with_handler(initial_state)
|> Reader.with_handler(config)
|> Port.with_handler(%{Repo => Repo.Ecto})
|> Fresh.with_uuid7_handler()
|> Throw.with_handler()
|> Comp.run!()
```

## Parameterised stacks

Define handler stacks as functions parameterised by mode:

```elixir
defmodule MyApp.Stacks do
  def with_handlers(comp, opts) do
    mode = Keyword.get(opts, :mode, :production)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    comp
    |> Reader.with_handler(%{tenant_id: tenant_id}, tag: :context)
    |> with_persistence(mode)
    |> with_generation(mode)
    |> Throw.with_handler()
  end

  defp with_persistence(comp, :production) do
    comp
    |> Port.with_handler(%{Repo => Repo.Ecto})
    |> Transaction.Ecto.with_handler(MyApp.Repo)
  end

  defp with_persistence(comp, :test) do
    comp
    |> Port.with_handler(%{Repo => Repo.InMemory})
    |> Transaction.Noop.with_handler()
  end

  defp with_generation(comp, :production) do
    comp
    |> Fresh.with_uuid7_handler()
    |> Random.with_handler()
  end

  defp with_generation(comp, :test) do
    comp
    |> Fresh.with_test_handler()
    |> Random.with_handler(seed: 42)
  end
end
```

Usage:

```elixir
# Production
MyApp.Domain.process(cmd)
|> MyApp.Stacks.with_handlers(mode: :production, tenant_id: "t1")
|> Comp.run!()

# Test
MyApp.Domain.process(cmd)
|> MyApp.Stacks.with_handlers(mode: :test, tenant_id: "t1")
|> Comp.run!()
```

## Composing stacks

For applications with multiple domains, compose domain-specific stacks:

```elixir
defmodule MyApp.Stacks do
  def with_all_handlers(comp, opts) do
    comp
    |> with_user_handlers(opts)
    |> with_order_handlers(opts)
    |> with_common_handlers(opts)
  end

  def with_user_handlers(comp, opts) do
    mode = Keyword.get(opts, :mode, :production)
    case mode do
      :production ->
        Port.with_handler(comp, %{UserService => UserService.Ecto})
      :test ->
        Port.with_handler(comp, %{UserService => UserService.InMemory})
    end
  end

  def with_order_handlers(comp, opts) do
    mode = Keyword.get(opts, :mode, :production)
    case mode do
      :production ->
        Port.with_handler(comp, %{OrderService => OrderService.Ecto})
      :test ->
        Port.with_handler(comp, %{OrderService => OrderService.InMemory})
    end
  end

  def with_common_handlers(comp, opts) do
    mode = Keyword.get(opts, :mode, :production)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    comp
    |> Reader.with_handler(%{tenant_id: tenant_id}, tag: :context)
    |> with_persistence(mode)
    |> with_generation(mode)
    |> Throw.with_handler()
  end

  # ... with_persistence, with_generation as above
end
```

## Multiple Port handlers

`Port.with_handler/2` accepts a map, and multiple calls merge:

```elixir
comp
|> Port.with_handler(%{UserService => UserService.Ecto})
|> Port.with_handler(%{OrderService => OrderService.Ecto})
```

Both UserService and OrderService are resolvable. This lets different
parts of the stack install their own Port bindings independently.

## Tagged handler instances

Several effects support tags for multiple independent instances:

```elixir
comp do
  ctx <- Reader.ask(:context)
  config <- Reader.ask(:config)
  {ctx, config}
end
|> Reader.with_handler(%{tenant_id: "t1"}, tag: :context)
|> Reader.with_handler(%{feature_flags: [:v2]}, tag: :config)
|> Comp.run!()
```

This works for State, Reader, Writer, and AtomicState.

## Why handler order usually doesn't matter

Each effect has a unique signature (typically its module atom). When
a handler is installed, it registers in the environment's `evidence`
map under that key. When an effect operation runs, it looks up its
handler by key in constant time. There is no chain of handlers that
effects pass through - only one handler applies to any given effect,
and it is found by direct map lookup.

This means for most stacks, the order of `with_handler` calls is
irrelevant to correctness. These two stacks are equivalent:

```elixir
# These produce identical behaviour:
comp |> State.with_handler(0) |> Reader.with_handler(cfg) |> Throw.with_handler()
comp |> Throw.with_handler() |> Reader.with_handler(cfg) |> State.with_handler(0)
```

## When order does matter

Order matters only when a handler **explicitly wraps other handlers**
to intercept their effects. This is rare - of the bundled effects,
only EffectLogger does this.

EffectLogger works by wrapping the handler functions of other effects
(via `wrap_handler/2`) so that it can log each effect invocation
before delegating to the real handler. Because it wraps handlers that
are already registered in the evidence map, **EffectLogger must be
installed before (closer to the computation than) the handlers it
wraps**. If installed after, the handlers it needs to wrap aren't
registered yet.

```elixir
comp
|> EffectLogger.with_logging()    # must come before handlers it wraps
|> State.with_handler(initial)    # EffectLogger wraps this handler
|> Reader.with_handler(config)    # and this one
|> Port.with_handler(port_map)
|> Transaction.Ecto.with_handler(Repo)
|> Throw.with_handler()
|> Comp.run!()
```

Apart from handler-wrapping effects like EffectLogger, all other
handlers are order-independent. Install them in whatever order reads
most clearly.

### Scoped handler cleanup order

While handler *dispatch* is order-independent, scoped handlers compose
their cleanup (`leave_scope`) and suspend decoration
(`transform_suspend`) chains. These chains run in reverse installation
order - later-installed handlers clean up first. This affects `output`
transform nesting (which handler's output wraps which), but not
correctness of effect dispatch itself.

## Tips

- Keep stack construction in dedicated modules, not inline
- Parameterise by mode, not by individual handler choice
- Use `defp` helpers for logical groupings (persistence, generation, etc.)
- Test stacks should be as close to production stacks as possible -
  only swap the implementations that touch infrastructure

<!-- nav:footer:start -->

---

[< The Decider Pattern](decider-pattern.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [LiveView Integration >](liveview.md)
<!-- nav:footer:end -->
