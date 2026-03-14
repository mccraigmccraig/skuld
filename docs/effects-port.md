# Effects: Port

Port abstracts blocking calls to external code behind a dispatch layer with
pluggable backends. It's ideal for wrapping database queries, HTTP calls, file
I/O, or any side-effecting code that effectful computations need to call out to
(or that non-effectful code needs to call in through).

The Port system has three layers:

- **Port** — low-level dispatch via `Port.request/3` with positional arguments
- **Port.Contract** — typed contracts via `defport` declarations, generating
  Dialyzer-checked callers, behaviour callbacks, and test key helpers
- **Port.Provider** — bridges effectful implementations back to plain Elixir
  interfaces, enabling the provider (inbound) side of hexagonal architecture

## Port (Low-Level API)

Dispatch parameterizable blocking calls to pluggable backends. Port uses
positional arguments — the third argument to `Port.request/3` is a list of args,
and dispatch uses `apply(module, name, args)`:

```elixir
use Skuld.Syntax
alias Skuld.Comp
alias Skuld.Effects.{Port, Throw}

# Define a module with side-effecting functions (positional args)
defmodule MyQueries do
  def find_user(id), do: {:ok, %{id: id, name: "User #{id}"}}
end

# Runtime: dispatch to actual modules
comp do
  user <- Port.request!(MyQueries, :find_user, [123])
  user
end
|> Port.with_handler(%{MyQueries => :direct})
|> Throw.with_handler()
|> Comp.run!()
#=> %{id: 123, name: "User 123"}

# Test: exact key matching with stub responses
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

# Test: function-based handler with pattern matching (ideal for property tests)
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

The function handler enables Elixir's full pattern matching power — pins, guards,
wildcards — making it ideal for property-based tests where exact values aren't
known upfront. Use `with_test_handler` for simple exact-match cases and
`with_fn_handler` for complex dynamic scenarios.

**Resolver types:**

- `:direct` — `apply(mod, name, args)` (call directly on the registered module)
- `module` — `apply(module, name, args)` (implementation module, for contract→impl dispatch)
- `fun/3` — `fun.(mod, name, args)` (function receives all three)
- `{module, function}` — `apply(module, function, [mod, name, args])`

## Port.Contract

For typed, Dialyzer-checked port operations, use `Port.Contract`. It generates
caller functions, behaviour submodules, test key helpers, and introspection from
`defport` declarations.

### Defining a contract

```elixir
defmodule MyApp.Repository do
  use Skuld.Effects.Port.Contract

  alias MyApp.Todo

  # Bang auto-generated: return type has {:ok, T}
  defport get_todo(tenant_id :: String.t(), id :: String.t()) ::
            {:ok, Todo.t()} | {:error, term()}

  defport list_todos(tenant_id :: String.t(), opts :: map()) ::
            {:ok, [Todo.t()]} | {:error, term()}

  # No bang auto-generated: return type is bare (no {:ok, T})
  defport health_check() :: :ok | {:error, term()}
end
```

This generates for each `defport`:

- **Caller** — `get_todo(tenant_id, id)` returning `computation({:ok, Todo.t()} | {:error, term()})`
- **Bang** (when applicable) — `get_todo!(tenant_id, id)` returning `computation(Todo.t())` (unwraps `{:ok, v}` or throws)
- **Key helper** — `key(:get_todo, tenant_id, id)` for test stub matching
- **Introspection** — `__port_operations__/0`

### Consumer and Provider behaviours

Each contract generates two behaviour submodules:

- **`MyApp.Repository.Consumer`** — plain Elixir callbacks. Implementations receive
  and return ordinary values. Use for non-effectful implementations called via
  `Port.with_handler/2`.
- **`MyApp.Repository.Provider`** — computation-returning callbacks. Implementations
  return `computation(return_type)`. Use for effectful implementations wrapped with
  `Port.Provider`.

```elixir
# Consumer behaviour (generated)
MyApp.Repository.Consumer
@callback get_todo(String.t(), String.t()) :: {:ok, Todo.t()} | {:error, term()}

# Provider behaviour (generated)
MyApp.Repository.Provider
@callback get_todo(String.t(), String.t()) :: computation({:ok, Todo.t()} | {:error, term()})
```

The contract module's own caller functions satisfy the Provider behaviour — they
return computations that emit Port effects.

### Bang variant generation

Bang variants (`name!`) are controlled by auto-detection with optional overrides
via the `bang:` option:

```elixir
defmodule MyApp.Users do
  use Skuld.Effects.Port.Contract

  # Auto-detect (default): bang generated because return type has {:ok, T}
  defport get_user(id :: String.t()) ::
            {:ok, User.t()} | {:error, term()}

  # Auto-detect: NO bang generated because return type has no {:ok, T}
  defport find_user(id :: String.t()) :: User.t() | nil

  # bang: true — force standard {:ok, v}/{:error, r} unwrapping even
  # when the return type doesn't match the pattern
  defport find_by_email(email :: String.t()) :: User.t() | nil, bang: true

  # bang: false — suppress bang even though return type has {:ok, T}
  defport raw_query(sql :: String.t()) ::
            {:ok, term()} | {:error, term()},
            bang: false

  # bang: custom_fn — generate bang using a custom unwrap function.
  # The function receives the raw implementation result and must
  # return {:ok, value} or {:error, reason}
  defport find_user_safe(id :: String.t()) :: User.t() | nil,
    bang: fn
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
end
```

This makes Contract easy to fit to **existing implementation code** regardless of
its return convention — implementations that return bare values, nillable results,
or custom result types can all have bang variants with appropriate unwrapping.

### Consumer implementations

Consumer implementations satisfy the `.Consumer` behaviour with plain Elixir
functions:

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

# Test: stub with generated key helpers
my_comp
|> Port.with_test_handler(%{
  MyApp.Repository.key(:get_todo, "tenant-1", "id-1") => {:ok, mock_todo}
})
|> Throw.with_handler()
|> Comp.run!()
```

### Benefits over raw `Port.request`

- Dialyzer checks call sites and implementations via `@spec` and `@callback`
- LSP autocomplete on `Repository.` shows available operations
- Missing callback implementations produce compiler warnings
- `key/N` helpers replace verbose `Port.key(Module, :name, [args...])` calls
- Bang generation adapts to any return convention via `bang:` option

## Port.Provider

Port.Provider enables the **provider side** of hexagonal architecture — where
plain Elixir code calls into effectful implementations. It generates a module
that satisfies the Consumer behaviour by wrapping a Provider-behaviour
implementation with a handler stack and `Comp.run!/1`.

### Defining a provider adapter

```elixir
# 1. Contract defines the port (same as before)
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
    user <- DB.get(User, id)
    {:ok, user}
  end

  defcomp list_users(opts) do
    users <- DB.all(User, opts)
    {:ok, users}
  end
end

# 3. Provider adapter satisfies Consumer behaviour, runs effectful impl
defmodule MyApp.UserService.Adapter do
  use Skuld.Effects.Port.Provider,
    contract: MyApp.UserService,
    impl: MyApp.UserService.Effectful,
    stack: fn comp ->
      comp
      |> DB.Ecto.with_handler(MyApp.Repo)
      |> Throw.with_handler()
    end
end
```

### Using the adapter

The adapter's functions return plain Elixir values — the effect stack is run
internally:

```elixir
# Direct call from non-effectful code
{:ok, user} = MyApp.UserService.Adapter.find_user("user-123")

# Or use it as a Port handler for effectful code
my_comp
|> Port.with_handler(%{MyApp.UserService => MyApp.UserService.Adapter})
|> Comp.run!()
```

### How it works

For each operation defined in the contract (via `__port_operations__/0`), the
adapter generates a function that:

1. Calls the impl module's corresponding function to get a computation
2. Pipes through the stack function to install effect handlers
3. Runs the computation with `Comp.run!/1`

Each call gets a fresh handler scope — the stack function creates new handler
installations per invocation.

### Stack function

The stack function receives a computation and returns a computation with
handlers installed. It's the composition point for all effect handlers the
implementation needs:

```elixir
# Simple: single effect
stack: &Throw.with_handler/1

# Complex: multiple effects
stack: fn comp ->
  comp
  |> State.with_handler(initial_state)
  |> DB.Ecto.with_handler(MyApp.Repo)
  |> Throw.with_handler()
end
```

### Hexagonal architecture

The Port system supports both directions of hexagonal architecture through the
same contract:

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

- **Consumer** — effectful code emits Port effects, resolved by
  `Port.with_handler/2` dispatching to a `.Consumer` implementation
- **Provider** — `Port.Provider` wraps a `.Provider` implementation (effectful)
  with a handler stack and `Comp.run!/1`, producing a `.Consumer`-compatible
  module that plain code can call directly

### Testing provider adapters

Provider adapters produce plain Elixir values, so they can be tested directly:

```elixir
test "adapter returns expected result" do
  result = MyApp.UserService.Adapter.find_user("user-123")
  assert {:ok, %User{id: "user-123"}} = result
end
```

To test the effectful implementation in isolation, use standard effect testing
patterns:

```elixir
test "effectful impl uses DB effect" do
  comp =
    MyApp.UserService.Effectful.find_user("user-123")
    |> DB.with_test_handler(...)
    |> Throw.with_handler()

  {result, _env} = Comp.run(comp)
  assert {:ok, %User{}} = result
end
```
