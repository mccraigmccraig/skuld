# Hexagonal Architecture

<!-- nav:header:start -->
[< Testing Effectful Code](testing.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [The Decider Pattern >](decider-pattern.md)
<!-- nav:header:end -->

Hexagonal architecture (ports and adapters) separates domain logic from
infrastructure by defining ports - interfaces that the domain uses to
communicate with the outside world. Skuld's Port.Contract and
Port.Provider map directly to the two directions of hexagonal ports.

## The two directions

**Consumer (outbound/driven)** - domain logic calls out to
infrastructure. "I need to fetch a user" becomes a Port effect that
gets resolved by whichever implementation is installed.

**Provider (inbound/driving)** - external code calls into domain logic.
A Phoenix controller or GenServer invokes effectful domain logic through
an adapter that handles the effect machinery.

## Defining the port

```elixir
defmodule MyApp.UserService do
  use Skuld.Effects.Port.Contract

  defport find_user(id :: String.t()) ::
            {:ok, User.t()} | {:error, term()}

  defport create_user(params :: map()) ::
            {:ok, User.t()} | {:error, term()}

  defport list_users(opts :: map()) ::
            {:ok, [User.t()]} | {:error, term()}
end
```

This generates Consumer and Provider behaviours, caller functions, bang
variants, and key helpers.

## Consumer side (outbound)

Domain logic uses the port as an effect. The implementation is pluggable.

### Domain logic

```elixir
defmodule MyApp.Onboarding do
  use Skuld.Syntax

  defcomp register(params) do
    user <- MyApp.UserService.create_user!(params)
    id <- Fresh.fresh_uuid()
    _ <- EventAccumulator.emit(%UserRegistered{
      id: id, user_id: user.id
    })
    {:ok, user}
  end
end
```

### Consumer implementation (Ecto)

```elixir
defmodule MyApp.UserService.Ecto do
  @behaviour MyApp.UserService.Consumer

  @impl true
  def find_user(id) do
    case Repo.get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @impl true
  def create_user(params) do
    %User{}
    |> User.changeset(params)
    |> Repo.insert()
  end

  @impl true
  def list_users(opts) do
    {:ok, Repo.all(User.query(opts))}
  end
end
```

### Consumer implementation (in-memory, for tests)

```elixir
defmodule MyApp.UserService.InMemory do
  @behaviour MyApp.UserService.Consumer

  # Backed by an Agent or ETS for test isolation
  use Agent

  def start_link(initial \\ []) do
    Agent.start_link(fn -> Map.new(initial, &{&1.id, &1}) end,
      name: __MODULE__)
  end

  @impl true
  def find_user(id) do
    case Agent.get(__MODULE__, &Map.get(&1, id)) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @impl true
  def create_user(params) do
    user = struct(User, Map.put(params, :id, Ecto.UUID.generate()))
    Agent.update(__MODULE__, &Map.put(&1, user.id, user))
    {:ok, user}
  end

  @impl true
  def list_users(_opts) do
    {:ok, Agent.get(__MODULE__, &Map.values/1)}
  end
end
```

### Wiring

```elixir
# Production
MyApp.Onboarding.register(params)
|> Port.with_handler(%{MyApp.UserService => MyApp.UserService.Ecto})
|> Fresh.with_uuid7_handler()
|> EventAccumulator.with_handler(output: fn r, e -> {r, e} end)
|> Throw.with_handler()
|> Comp.run!()

# Test
MyApp.Onboarding.register(params)
|> Port.with_handler(%{MyApp.UserService => MyApp.UserService.InMemory})
|> Fresh.with_test_handler()
|> EventAccumulator.with_handler(output: fn r, e -> {r, e} end)
|> Throw.with_handler()
|> Comp.run!()
```

## Provider side (inbound)

When plain Elixir code (a Phoenix controller, a GenServer, a CLI)
needs to call effectful domain logic, Port.Provider bridges the gap.

### Effectful implementation

```elixir
defmodule MyApp.UserService.Effectful do
  use Skuld.Syntax
  @behaviour MyApp.UserService.Provider

  defcomp find_user(id) do
    user <- DB.get(User, id)
    case user do
      nil -> {:error, :not_found}
      u -> {:ok, u}
    end
  end

  defcomp create_user(params) do
    changeset = User.changeset(%User{}, params)
    user <- DB.insert(changeset)
    _ <- EventAccumulator.emit(%UserCreated{user_id: user.id})
    {:ok, user}
  end

  defcomp list_users(opts) do
    # Use Port for the query (reads go through Port)
    users <- Port.request!(Queries, :list_users, [opts])
    {:ok, users}
  end
end
```

### Provider adapter

```elixir
defmodule MyApp.UserService.Adapter do
  use Skuld.Effects.Port.Provider,
    contract: MyApp.UserService,
    impl: MyApp.UserService.Effectful,
    stack: fn comp ->
      comp
      |> DB.Ecto.with_handler(MyApp.Repo)
      |> Port.with_handler(%{Queries => Queries.Ecto})
      |> EventAccumulator.with_handler(
        output: fn r, events ->
          MyApp.EventBus.publish(events)
          r
        end
      )
      |> Throw.with_handler()
    end
end
```

### Usage from plain Elixir

```elixir
# Phoenix controller
def create(conn, params) do
  case MyApp.UserService.Adapter.create_user(params) do
    {:ok, user} -> json(conn, user)
    {:error, reason} -> json(conn, %{error: reason})
  end
end
```

The caller doesn't know about effects, computations, or handlers. It
calls a plain Elixir function and gets a plain Elixir value back.

## Full picture

```
                    UserService
                    (defport)
                   /          \
     Consumer side              Provider side
     (outbound)                 (inbound)
          |                          |
     Domain computations        Phoenix controllers
     call UserService.*         call Adapter.*
          |                          |
     Port.with_handler          Port.Provider
     → Ecto impl (prod)        → Effectful impl
     → InMemory impl (test)      → handler stack
                                   → Comp.run!()
```

## Tips

- Define one contract per bounded context or aggregate (UserService,
  OrderService, etc.)
- Keep Consumer implementations thin - just infrastructure calls
- The in-memory implementation is your test double - no mocks needed
- Provider adapters are where you compose the full handler stack
- Include `Throw.with_handler/1` in the stack if computations can
  throw - without it, `Comp.run!/1` raises `ThrowError`

<!-- nav:footer:start -->

---

[< Testing Effectful Code](testing.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [The Decider Pattern >](decider-pattern.md)
<!-- nav:footer:end -->
