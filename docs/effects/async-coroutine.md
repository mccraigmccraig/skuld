# AsyncCoroutine

Run a coroutine in a separate BEAM process, bridging yields, errors,
and results back to the caller via messages. This is the bridge from
non-effectful code (LiveView, GenServer, CLI) into the effect system.

## Starting

```elixir
# Async — result arrives via message
{:ok, runner} = AsyncCoroutine.run(computation, tag: :my_task)

# Sync — block until first response (yield or completion)
{:ok, runner, %ExternalSuspend{value: :ready}} =
  AsyncCoroutine.run_sync(computation, tag: :my_task)
```

`Throw.with_handler` and `Yield.with_handler` are added automatically.

## Messages

All messages arrive as `{AsyncCoroutine, tag, result}`:

```elixir
def handle_info({AsyncCoroutine, :my_task, result}, socket) do
  case result do
    %ExternalSuspend{value: v, data: d} -> handle_yield(v, d, socket)
    %Throw{error: e}                    -> handle_error(e, socket)
    %Cancelled{reason: r}               -> handle_cancelled(r, socket)
    value                               -> handle_success(value, socket)
  end
end
```

The `ExternalSuspend.data` field carries scoped effect state (e.g.
EffectLogger's log) — populated by `transform_suspend` at yield points.

## Resume and cancel

```elixir
# Async resume — next response via message
:ok = AsyncCoroutine.run(runner, "Alice")

# Sync resume — block until response
case AsyncCoroutine.run_sync(runner, "Alice") do
  %ExternalSuspend{value: :get_email} -> # yielded again
  {:ok, user}                         -> # completed
  %Throw{error: e}                    -> # error
end

# Cancel — cleanup via leave_scope
:ok = AsyncCoroutine.cancel(runner)
%Cancelled{reason: :cancelled} = AsyncCoroutine.cancel_sync(runner)
```

## Multi-step wizard

```elixir
wizard = comp do
  name <- Yield.yield(:get_name)
  email <- Yield.yield(:get_email)
  {:ok, %{name: name, email: email}}
end |> Reader.with_handler(%{...})

{:ok, runner} = AsyncCoroutine.run(wizard, tag: :wizard)

# In handle_info:
def handle_info({AsyncCoroutine, :wizard, %ExternalSuspend{value: :get_name}}, socket) do
  AsyncCoroutine.run(socket.assigns.runner, "Alice")
  {:noreply, socket}
end
def handle_info({AsyncCoroutine, :wizard, %ExternalSuspend{value: :get_email}}, socket) do
  AsyncCoroutine.run(socket.assigns.runner, "alice@example.com")
  {:noreply, socket}
end
def handle_info({AsyncCoroutine, :wizard, {:ok, user}}, socket) do
  {:noreply, assign(socket, user: user)}
end
```

## API

| Function | Purpose |
|----------|---------|
| `run/2` | Start in new process (async) |
| `run_sync/2` | Start + block for first response |
| `run/3` | Resume with value (async) |
| `run_sync/3` | Resume + block for response |
| `cancel/1` | Cancel (async) |
| `cancel_sync/2` | Cancel + block for completion |
