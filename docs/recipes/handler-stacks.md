# Handler Stacks

Handler stacks are the composition point where you wire effects to
implementations. A well-structured stack makes it easy to switch
between production, test, and development configurations.

## The basics

Handlers are installed by piping a computation through `with_handler`
functions. Order matters: handlers installed later (outermost) see
effects first.

```elixir
my_computation
|> State.with_handler(initial_state)
|> Reader.with_handler(config)
|> Port.with_handler(%{Repo => Repo.Ecto})
|> DB.Ecto.with_handler(MyApp.Repo)
|> Fresh.with_uuid7_handler()
|> Throw.with_handler()        # outermost - catches all throws
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
    |> DB.Ecto.with_handler(MyApp.Repo)
  end

  defp with_persistence(comp, :test) do
    comp
    |> Port.with_handler(%{Repo => Repo.InMemory})
    |> DB.Noop.with_handler()
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

## Handler ordering rules

1. **Throw goes last** (outermost) - it catches throws from all inner
   handlers
2. **Yield goes before State** - State's `suspend` option needs Yield
   to be handled first
3. **FiberPool goes outermost** among concurrency effects - Channel
   and Brook handlers go inside FiberPool
4. **Port handlers can go anywhere** - they're looked up by key, not
   position
5. **EffectLogger goes inside Yield/State** - it needs to intercept
   their effects

Example ordering for a full stack:

```elixir
comp
|> EffectLogger.with_logging()           # innermost - logs effects
|> State.with_handler(initial)           # state management
|> Reader.with_handler(config)           # environment
|> Port.with_handler(port_map)           # external calls
|> DB.Ecto.with_handler(Repo)            # database
|> Fresh.with_uuid7_handler()            # UUID generation
|> EventAccumulator.with_handler(...)    # domain events
|> Channel.with_handler()                # channels (if using Brook)
|> FiberPool.with_handler()              # fiber scheduling
|> Yield.with_handler()                  # coroutine support
|> Throw.with_handler()                  # error handling (outermost)
|> Comp.run!()
```

## Tips

- Keep stack construction in dedicated modules, not inline
- Parameterise by mode, not by individual handler choice
- Use `defp` helpers for logical groupings (persistence, generation, etc.)
- Test stacks should be as close to production stacks as possible -
  only swap the implementations that touch infrastructure
