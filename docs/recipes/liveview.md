# LiveView Integration

AsyncComputation bridges effectful computations into Phoenix LiveView,
enabling multi-step wizards, long-running operations, and interactive
workflows where a computation yields for user input.

## The pattern

1. Build a computation that yields at each user-interaction point
2. Start it with `AsyncComputation.start/2`
3. Handle messages in `handle_info/2`
4. Resume with user input via `AsyncComputation.resume/2`

## Example: a multi-step wizard

```elixir
defmodule MyAppWeb.WizardLive do
  use MyAppWeb, :live_view

  alias Skuld.AsyncComputation
  alias Skuld.Comp.{Suspend, Throw, Cancelled}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, step: nil, runner: nil, result: nil)}
  end

  # Start the wizard computation
  def handle_event("start", _params, socket) do
    computation =
      comp do
        name <- Yield.yield(%{step: :name, prompt: "What's your name?"})
        email <- Yield.yield(%{step: :email, prompt: "What's your email?"})
        plan <- Yield.yield(%{step: :plan, prompt: "Choose a plan",
                              options: [:free, :pro, :enterprise]})

        # Use effects for the actual work
        user <- MyApp.UserService.create_user!(%{
          name: name, email: email, plan: plan
        })
        _ <- EventAccumulator.emit(%UserOnboarded{user_id: user.id})
        {:ok, user}
      end
      |> MyApp.Stacks.with_handlers(mode: :production, tenant_id: "t1")

    {:ok, runner} = AsyncComputation.start(computation, tag: :wizard)
    {:noreply, assign(socket, runner: runner)}
  end

  # Handle all wizard messages
  def handle_info({AsyncComputation, :wizard, result}, socket) do
    case result do
      %Suspend{value: %{step: step} = prompt} ->
        {:noreply, assign(socket, step: step, prompt: prompt)}

      %Throw{error: error} ->
        {:noreply,
          socket
          |> assign(runner: nil, step: nil)
          |> put_flash(:error, "Error: #{inspect(error)}")}

      %Cancelled{reason: _reason} ->
        {:noreply, assign(socket, runner: nil, step: nil)}

      {:ok, user} ->
        {:noreply,
          socket
          |> assign(result: user, runner: nil, step: nil)
          |> put_flash(:info, "Welcome, #{user.name}!")}
    end
  end

  # User submits a step
  def handle_event("submit", %{"value" => value}, socket) do
    AsyncComputation.resume(socket.assigns.runner, value)
    {:noreply, assign(socket, step: nil)}
  end

  # Cancel the wizard
  def handle_event("cancel", _params, socket) do
    if socket.assigns.runner do
      AsyncComputation.cancel(socket.assigns.runner)
    end
    {:noreply, assign(socket, runner: nil, step: nil)}
  end
end
```

## Synchronous start

For computations that yield quickly (e.g., the first step is immediate),
use `start_sync/2` to avoid a render cycle:

```elixir
{:ok, runner, %Suspend{value: first_prompt}} =
  AsyncComputation.start_sync(computation, tag: :wizard, timeout: 5000)

{:noreply,
  socket
  |> assign(runner: runner, step: first_prompt.step, prompt: first_prompt)}
```

Similarly, `resume_sync/3` blocks until the next yield/result:

```elixir
case AsyncComputation.resume_sync(runner, value, timeout: 5000) do
  %Suspend{value: next_prompt} ->
    {:noreply, assign(socket, step: next_prompt.step, prompt: next_prompt)}
  {:ok, result} ->
    {:noreply, assign(socket, result: result, runner: nil)}
  %Throw{error: error} ->
    {:noreply, put_flash(socket, :error, inspect(error))}
  {:error, :timeout} ->
    {:noreply, put_flash(socket, :error, "Operation timed out")}
end
```

## Key points

- AsyncComputation automatically adds `Throw.with_handler/1` and
  `Yield.with_handler/1` - don't add them to your stack
- Messages arrive as `{AsyncComputation, tag, result}` - single
  pattern match handles all cases
- Elixir exceptions become
  `%Throw{error: %{kind: :error, payload: exception}}`
- Cancellation triggers proper cleanup via `leave_scope`
- Linked by default (use `link: false` for unlinked runners)
- `Suspend.data` carries decorations from scoped effects (e.g.,
  `data[EffectLogger]` has the current effect log)

## With EffectLogger for durable wizards

Combine AsyncComputation with EffectLogger to persist wizard state
across page refreshes or server restarts:

```elixir
computation =
  comp do
    name <- Yield.yield(%{step: :name})
    email <- Yield.yield(%{step: :email})
    {:ok, %{name: name, email: email}}
  end
  |> EffectLogger.with_logging()
  |> MyApp.Stacks.with_handlers(mode: :production, tenant_id: "t1")

{:ok, runner} = AsyncComputation.start(computation, tag: :wizard)
```

When the computation suspends, extract and persist the log from
`Suspend.data[EffectLogger]`. On page reload, cold-resume from the
persisted log. See [Durable Workflows](durable-workflows.md) for the
full pattern.
