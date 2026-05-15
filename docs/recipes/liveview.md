# LiveView Integration

<!-- nav:header:start -->
[< Handler Stacks](handler-stacks.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [The Decider Pattern >](decider-pattern.md)
<!-- nav:header:end -->

`AsyncCoroutine` bridges effectful computations into Phoenix LiveView,
enabling multi-step wizards, conversational flows, and long-running
operations without GenServer boilerplate.

## Pattern

1. Write the wizard as an effectful computation using `Yield`
2. Start it with `AsyncCoroutine.run/2`
3. Handle `{AsyncCoroutine, tag, result}` messages in `handle_info`
4. Resume with user input via `AsyncCoroutine.run/3`

## Multi-step wizard

```elixir
alias Skuld.AsyncCoroutine

defmodule MyApp.Wizard do
  use Skuld.Syntax

  defcomp run do
    name <- Yield.yield(:get_name)
    email <- Yield.yield(:get_email)
    {:ok, %{name: name, email: email}}
  end
end
```

LiveView:

```elixir
def mount(_params, _session, socket) do
  {:ok, runner} = AsyncCoroutine.run(MyApp.Wizard.run(), tag: :wizard)
  {:ok, assign(socket, runner: runner, step: :name)}
end

def handle_info({AsyncCoroutine, :wizard, %ExternalSuspend{value: :get_name}}, socket) do
  {:noreply, assign(socket, step: :name)}
end

def handle_event("submit_name", %{"name" => name}, socket) do
  AsyncCoroutine.run(socket.assigns.runner, name)
  {:noreply, socket}
end

def handle_info({AsyncCoroutine, :wizard, %ExternalSuspend{value: :get_email}}, socket) do
  {:noreply, assign(socket, step: :email)}
end

def handle_info({AsyncCoroutine, :wizard, {:ok, user}}, socket) do
  {:noreply, assign(socket, user: user, step: :done)}
end
```

## Cancellation

Cancel on mount or when the user navigates away:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    # Cancel any previous wizard
    if socket.assigns[:runner], do: AsyncCoroutine.cancel(socket.assigns.runner)
  end
  ...
end
```

## With EffectLogger

Persist wizard state for resumption after disconnects:

```elixir
wizard = MyApp.Wizard.run()
|> EffectLogger.with_logging()
|> Reader.with_handler(%{})

{:ok, runner} = AsyncCoroutine.run(wizard, tag: :wizard)
# Extract log from ExternalSuspend.data when yielded
```

| Operation | Purpose |
|-----------|---------|
| `AsyncCoroutine.run/2` | Start wizard (async) |
| `AsyncCoroutine.run_sync/2` | Start + block for first yield |
| `AsyncCoroutine.run/3` | Resume with input |
| `AsyncCoroutine.cancel/1` | Cancel wizard |

<!-- nav:footer:start -->

---

[< Handler Stacks](handler-stacks.md) | [Up: Recipes](hexagonal-architecture.md) | [Index](../../README.md) | [The Decider Pattern >](decider-pattern.md)
<!-- nav:footer:end -->
