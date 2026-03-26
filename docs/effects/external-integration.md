# External Integration

<!-- nav:header:start -->
[< Persistence & Data](persistence.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [Yield (Coroutines) >](../advanced/yield.md)
<!-- nav:header:end -->

The Port system abstracts calls to external code - database reads, HTTP
APIs, file I/O, or any side-effecting function - behind a dispatch layer
with pluggable backends. This makes external dependencies trivially
swappable for testing.

Port has three layers:

- **Port** - low-level dispatch via `Port.request/3`
- **Port.Contract** - typed contracts via `defport`, with Dialyzer support
  and generated behaviours
- **Port.Provider** - bridges plain Elixir code into effectful
  implementations (the inbound side of hexagonal architecture)

Most applications should use Port.Contract. The low-level Port API is
useful for quick prototyping or when you need maximum flexibility.

## Port (Low-Level API)

Dispatch parameterised blocking calls to pluggable backends. Port uses
positional arguments - `Port.request/3` takes a module, function name,
and args list.

### Basic usage

```elixir
defmodule MyQueries do
  def find_user(id), do: {:ok, %{id: id, name: "User #{id}"}}
end

# Production: dispatch to actual module
comp do
  user <- Port.request!(MyQueries, :find_user, [123])
  user
end
|> Port.with_handler(%{MyQueries => :direct})
|> Throw.with_handler()
|> Comp.run!()
#=> %{id: 123, name: "User 123"}
```

### Operations

- `Port.request(mod, name, args)` - dispatch a call, returns the raw
  result (e.g. `{:ok, value}` or `{:error, reason}`)
- `Port.request!(mod, name, args)` - dispatch a call, unwraps `{:ok, v}`
  or throws on `{:error, r}`

### Handler

```elixir
Port.with_handler(dispatch_map)
```

The dispatch map keys are modules and values are resolvers:

- `:direct` - `apply(mod, name, args)` (call directly on the keyed module)
- `module` - `apply(module, name, args)` (dispatch to an implementation module)
- `fun/3` - `fun.(mod, name, args)` (function receives all three)
- `{module, function}` - `apply(module, function, [mod, name, args])`

### Testing patterns

**Exact-match stubs** for simple cases:

```elixir
comp do
  user <- Port.request!(MyQueries, :find_user, [456])
  user
end
|> Port.with_test_handler(%{
  Port.key(MyQueries, :find_user, [456]) => {:ok, %{id: 456, name: "Stubbed"}}
})
|> Throw.with_handler()
|> Comp.run!()
#=> %{id: 456, name: "Stubbed"}
```

**Function-based handler** for pattern matching (ideal for property tests
where exact values aren't known upfront):

```elixir
comp do
  user <- Port.request!(MyQueries, :find_user, [789])
  user
end
|> Port.with_fn_handler(fn
  MyQueries, :find_user, [id] -> {:ok, %{id: id, name: "Generated User #{id}"}}
  MyQueries, :list_users, [limit] when limit > 100 -> {:error, :limit_too_high}
  _mod, _fun, _args -> {:ok, :default}
end)
|> Throw.with_handler()
|> Comp.run!()
#=> %{id: 789, name: "Generated User 789"}
```

The function handler gives you full Elixir pattern matching power -
pins, guards, wildcards. Use `with_test_handler` for exact-match cases
and `with_fn_handler` for dynamic scenarios.

## Port.Contract

Typed contracts via `defport` declarations. Generates Dialyzer-checked
caller functions, behaviour callbacks, test key helpers, and
introspection. This is the recommended way to define ports.

### Defining a contract

```elixir
defmodule MyApp.Repository do
  use Skuld.Effects.Port.Contract

  alias MyApp.Todo

  defport get_todo(tenant_id :: String.t(), id :: String.t()) ::
            {:ok, Todo.t()} | {:error, term()}

  defport list_todos(tenant_id :: String.t(), opts :: map()) ::
            {:ok, [Todo.t()]} | {:error, term()}

  defport health_check() :: :ok | {:error, term()}
end
```

Each `defport` generates:

- **Caller** - `get_todo(tenant_id, id)` returning a computation
- **Bang** (when applicable) - `get_todo!(tenant_id, id)` unwrapping
  `{:ok, v}` or throwing on `{:error, r}`
- **Key helper** - `key(:get_todo, tenant_id, id)` for test stubs
- **Introspection** - `__port_operations__/0`

### Consumer and Provider behaviours

Each contract generates two behaviour submodules:

- **`MyApp.Repository.Consumer`** - plain Elixir callbacks. Implementations
  receive and return ordinary values. Use for non-effectful implementations
  called via `Port.with_handler/2`.
- **`MyApp.Repository.Provider`** - computation-returning callbacks.
  Implementations return computations. Use for effectful implementations
  wrapped with `Port.Provider`.

```elixir
# Consumer behaviour (generated)
MyApp.Repository.Consumer
@callback get_todo(String.t(), String.t()) :: {:ok, Todo.t()} | {:error, term()}

# Provider behaviour (generated)
MyApp.Repository.Provider
@callback get_todo(String.t(), String.t()) :: computation({:ok, Todo.t()} | {:error, term()})
```

### Bang variant generation

Bang variants are auto-detected based on return type and can be
overridden:

```elixir
defmodule MyApp.Users do
  use Skuld.Effects.Port.Contract

  # Auto: bang generated (return type has {:ok, T})
  defport get_user(id :: String.t()) ::
            {:ok, User.t()} | {:error, term()}

  # Auto: NO bang (return type has no {:ok, T})
  defport find_user(id :: String.t()) :: User.t() | nil

  # Force bang with standard {:ok, v}/{:error, r} unwrapping
  defport find_by_email(email :: String.t()) :: User.t() | nil, bang: true

  # Suppress bang
  defport raw_query(sql :: String.t()) ::
            {:ok, term()} | {:error, term()},
            bang: false

  # Custom unwrap function
  defport find_user_safe(id :: String.t()) :: User.t() | nil,
    bang: fn
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
end
```

This makes Contract easy to fit to existing implementation code
regardless of its return convention.

### Writing a Consumer implementation

Consumer implementations satisfy the `.Consumer` behaviour with plain
Elixir functions:

```elixir
defmodule MyApp.Repository.Ecto do
  @behaviour MyApp.Repository.Consumer

  @impl true
  def get_todo(tenant_id, id) do
    case Repo.get_by(Todo, tenant_id: tenant_id, id: id) do
      nil -> {:error, {:not_found, Todo, id}}
      todo -> {:ok, todo}
    end
  end

  @impl true
  def list_todos(tenant_id, opts), do: ...

  @impl true
  def health_check, do: :ok
end
```

### Handler installation

```elixir
# Production: dispatch to Ecto implementation
my_comp
|> Port.with_handler(%{MyApp.Repository => MyApp.Repository.Ecto})
|> Comp.run!()

# Test: dispatch to in-memory implementation
my_comp
|> Port.with_handler(%{MyApp.Repository => MyApp.Repository.InMemory})
|> Comp.run!()

# Test: stub specific calls with generated key helpers
my_comp
|> Port.with_test_handler(%{
  MyApp.Repository.key(:get_todo, "tenant-1", "id-1") => {:ok, mock_todo}
})
|> Throw.with_handler()
|> Comp.run!()
```

### Benefits over raw Port

- Dialyzer checks call sites and implementations via `@spec` and `@callback`
- LSP autocomplete on `Repository.` shows available operations
- Missing callback implementations produce compiler warnings
- `key/N` helpers replace verbose `Port.key(Module, :name, [args...])` calls
- Bang generation adapts to any return convention via `bang:` option

## Port.Provider

Port.Provider enables the **provider side** of hexagonal architecture:
plain Elixir code calling into effectful implementations. It generates a
module that satisfies the Consumer behaviour by wrapping a Provider
implementation with a handler stack and `Comp.run!/1`.

### When to use Port.Provider

Use Port.Provider when non-effectful code (a Phoenix controller, a
GenServer, a CLI) needs to call into logic that's written with effects.
The adapter handles the effect machinery so callers don't need to know
about it.

### Defining a provider adapter

```elixir
# 1. Contract defines the port (same as above)
defmodule MyApp.UserService do
  use Skuld.Effects.Port.Contract
  defport find_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()}
  defport list_users(opts :: map()) :: {:ok, [User.t()]} | {:error, term()}
end

# 2. Effectful implementation satisfies Provider behaviour
defmodule MyApp.UserService.Effectful do
  use Skuld.Syntax
  @behaviour MyApp.UserService.Provider

  defcomp find_user(id) do
    UserQueries.get_user(id)
  end

  defcomp list_users(opts) do
    UserQueries.list_users(opts)
  end
end

# 3. Provider adapter bridges effectful impl to plain Elixir
defmodule MyApp.UserService.Adapter do
  use Skuld.Effects.Port.Provider,
    contract: MyApp.UserService,
    impl: MyApp.UserService.Effectful,
    stack: fn comp ->
      comp
      |> Port.with_handler(%{UserQueries => UserQueries.Ecto})
      |> Throw.with_handler()
    end
end
```

### Using the adapter

The adapter returns plain Elixir values - the effect stack runs
internally:

```elixir
# Direct call from non-effectful code (controllers, GenServers, etc.)
{:ok, user} = MyApp.UserService.Adapter.find_user("user-123")

# Or use it as a Port handler for effectful code
my_comp
|> Port.with_handler(%{MyApp.UserService => MyApp.UserService.Adapter})
|> Comp.run!()
```

### The stack function

The stack function receives a computation and returns a computation with
handlers installed. It's where you compose all the effect handlers the
implementation needs:

```elixir
# Simple: single effect
stack: &Throw.with_handler/1

# Complex: multiple effects
stack: fn comp ->
  comp
  |> State.with_handler(initial_state)
  |> Port.with_handler(%{MyRepo => MyRepo.Ecto})
  |> Throw.with_handler()
end
```

> **Note:** If the effectful implementation can throw (via Throw), the
> stack function **must** include `Throw.with_handler/1`. Without it,
> `Comp.run!/1` raises `ThrowError`. The position of Throw in the
> handler pipeline doesn't matter - it just needs to be installed.

### Hexagonal architecture

The Port system supports both directions of hexagonal architecture
through the same contract:

```
                    Contract
                   (defport)
                  /          \
    Consumer side              Provider side
    (outbound/driven)          (inbound/driving)
         |                          |
    Effectful code             Plain Elixir code
    calls out to               calls in to
    plain Elixir impl          effectful impl
         |                          |
    Port.with_handler          Port.Provider
    → Consumer impl            → Provider impl
                                 → stack
                                 → Comp.run!()
```

- **Consumer (outbound)** - effectful code emits Port effects, resolved
  by `Port.with_handler/2` dispatching to a Consumer implementation
- **Provider (inbound)** - `Port.Provider` wraps a Provider
  implementation with a handler stack and `Comp.run!/1`, producing a
  Consumer-compatible module that plain code calls directly

### Testing provider adapters

Provider adapters produce plain Elixir values, so they test like
ordinary Elixir code:

```elixir
test "adapter returns expected result" do
  result = MyApp.UserService.Adapter.find_user("user-123")
  assert {:ok, %User{id: "user-123"}} = result
end
```

To test the effectful implementation in isolation, use standard effect
testing patterns:

```elixir
test "effectful impl uses Port effect" do
  result =
    MyApp.UserService.Effectful.find_user("user-123")
    |> Port.with_test_handler(%{
      UserQueries.key(:get_user, "user-123") => {:ok, %User{id: "user-123"}}
    })
    |> Throw.with_handler()
    |> Comp.run!()

  assert {:ok, %User{}} = result
end
```

<!-- nav:footer:start -->

---

[< Persistence & Data](persistence.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [Yield (Coroutines) >](../advanced/yield.md)
<!-- nav:footer:end -->
