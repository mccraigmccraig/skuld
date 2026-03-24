# Concurrency (Familiar Patterns)

<!-- nav:header:start -->
[< Collections](collections.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [Persistence & Data >](persistence.md)
<!-- nav:header:end -->

These concurrency effects wrap BEAM patterns you already know (tasks,
agents) with effect-based interfaces, giving you testability and
composition with the rest of the effect system.

For cooperative fiber-based concurrency (FiberPool, Channel, Brook),
see [Advanced Effects](../advanced/fibers-concurrency.md).

## Parallel

Fork-join concurrency. Run multiple computations concurrently and
collect their results.

### Basic usage

```elixir
comp do
  Parallel.all([
    comp do %{id: 1, name: "Alice"} end,
    comp do %{id: 2, name: "Bob"} end,
    comp do %{id: 3, name: "Carol"} end
  ])
end
|> Parallel.with_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}, %{id: 3, name: "Carol"}]
```

### Operations

- `Parallel.all(computations)` - run all, return all results. First
  failure returns `{:error, {:task_failed, reason}}`.
- `Parallel.race(computations)` - return first to complete, cancel
  others. Failures ignored unless all fail.
- `Parallel.map(list, fun)` - map over items in parallel.

### Error handling

Task failures are caught and wrapped. For `all/1` and `map/2`, the first
failure short-circuits. For `race/1`, failures are ignored unless all
tasks fail.

### Testing

The sequential handler runs tasks one at a time for deterministic tests:

```elixir
comp do
  Parallel.all([comp do :a end, comp do :b end])
end
|> Parallel.with_sequential_handler()
|> Throw.with_handler()
|> Comp.run!()
#=> [:a, :b]
```

## AtomicState

Thread-safe state for concurrent contexts. Unlike State (which stores
values in `env.state` and gets copied when forking), AtomicState uses
an Agent for safe cross-process access.

### Basic usage

```elixir
comp do
  _ <- AtomicState.put(0)
  _ <- AtomicState.modify(&(&1 + 1))
  AtomicState.get()
end
|> AtomicState.with_agent_handler(0)
|> Comp.run!()
#=> 1
```

### Compare-and-swap

```elixir
comp do
  _ <- AtomicState.put(10)
  r1 <- AtomicState.cas(10, 20)  # succeeds: current == expected
  r2 <- AtomicState.cas(10, 30)  # fails: current is 20, not 10
  final <- AtomicState.get()
  {r1, r2, final}
end
|> AtomicState.with_agent_handler(0)
|> Comp.run!()
#=> {:ok, {:conflict, 20}, 20}
```

### Tagged usage

Multiple independent atomic states:

```elixir
comp do
  _ <- AtomicState.modify(:counter, &(&1 + 1))
  _ <- AtomicState.modify(:cache, &Map.put(&1, :key, "value"))
  counter <- AtomicState.get(:counter)
  cache <- AtomicState.get(:cache)
  {counter, cache}
end
|> AtomicState.with_agent_handler(0, tag: :counter)
|> AtomicState.with_agent_handler(%{}, tag: :cache)
|> Comp.run!()
#=> {1, %{key: "value"}}
```

### Operations

`get/1`, `put/2`, `modify/2`, `atomic_state/2` (get-and-update), `cas/3`

### Testing

State-backed handler (no Agent processes, deterministic):

```elixir
comp do
  _ <- AtomicState.modify(&(&1 + 10))
  AtomicState.get()
end
|> AtomicState.with_state_handler(5)
|> Comp.run!()
#=> 15
```

## AsyncComputation

Bridge effectful computations into non-effectful code (LiveView,
GenServer, plain Elixir). Handles the suspend/resume lifecycle via
messages.

### Basic usage

```elixir
alias Skuld.AsyncComputation
alias Skuld.Comp.{Suspend, Throw, Cancelled}

computation =
  comp do
    name <- Yield.yield(:get_name)
    email <- Yield.yield(:get_email)
    {:ok, %{name: name, email: email}}
  end
  |> Reader.with_handler(%{tenant_id: "t-123"})

# Start async - returns immediately, responses arrive as messages
{:ok, runner} = AsyncComputation.start(computation, tag: :create_user)

# Or start sync - blocks until first yield/result/throw
{:ok, runner, %Suspend{value: :get_name}} =
  AsyncComputation.start_sync(computation, tag: :create_user, timeout: 5000)
```

### Message format

All messages arrive as `{AsyncComputation, tag, result}`:

- `%Suspend{value: v, data: d}` - computation yielded
- `%Throw{error: e}` - computation threw
- `%Cancelled{reason: r}` - computation was cancelled
- plain value - computation completed

### Resume and cancel

```elixir
# Async resume - returns immediately
AsyncComputation.resume(runner, "Alice")

# Sync resume - blocks until next yield/result/throw
case AsyncComputation.resume_sync(runner, "Alice", timeout: 5000) do
  %Suspend{value: next_prompt} -> # yielded again
  %Throw{error: error} -> # threw
  value -> # completed
end

# Cancel - triggers cleanup via leave_scope
AsyncComputation.cancel(runner)
```

### LiveView example

```elixir
def handle_event("start_wizard", _params, socket) do
  computation =
    comp do
      name <- Yield.yield(%{step: 1, prompt: "Enter name"})
      email <- Yield.yield(%{step: 2, prompt: "Enter email"})
      {:ok, %{name: name, email: email}}
    end
    |> MyApp.with_domain_handlers()

  {:ok, runner} = AsyncComputation.start(computation, tag: :wizard)
  {:noreply, assign(socket, runner: runner)}
end

def handle_info({AsyncComputation, :wizard, result}, socket) do
  case result do
    %Suspend{value: %{step: step, prompt: prompt}} ->
      {:noreply, assign(socket, step: step, prompt: prompt)}
    %Throw{error: error} ->
      {:noreply, put_flash(socket, :error, inspect(error))}
    {:ok, user} ->
      {:noreply, assign(socket, user: user) |> put_flash(:info, "Created!")}
  end
end

def handle_event("submit_step", %{"value" => value}, socket) do
  AsyncComputation.resume(socket.assigns.runner, value)
  {:noreply, socket}
end
```

### Key points

- Adds Throw and Yield handlers automatically
- Uniform message format enables single-clause `handle_info`
- Cancellation triggers proper cleanup via `leave_scope`
- `Suspend.data` contains decorations from scoped effects (e.g.,
  EffectLogger log)
- Use AsyncComputation for non-effectful callers; use FiberPool when
  inside a computation

### Operations

`start/2`, `start_sync/2`, `resume/2`, `resume_sync/3`, `cancel/1`

<!-- nav:footer:start -->

---

[< Collections](collections.md) | [Up: Foundational Effects](state-environment.md) | [Index](../../README.md) | [Persistence & Data >](persistence.md)
<!-- nav:footer:end -->
