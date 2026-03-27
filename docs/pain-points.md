# What Skuld Solves

<!-- nav:header:start -->
[< What Are Algebraic Effects?](what.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Getting Started >](getting-started.md)
<!-- nav:header:end -->

You don't need to care about algebraic effects theory to benefit from
Skuld. Here are the concrete problems it addresses, framed as pain
you've probably already felt.

## Testing orchestration code

**The pain**: Your most important business logic - the orchestration
that ties together database access, external services, validation, and
domain rules - is the hardest code to test. You need Ecto sandboxes,
Mox stubs, and careful setup for every test. Tests are slow, brittle,
and coupled to infrastructure. Property-based testing of this code is
effectively impossible because each test run would hit real databases
and external services.

**What Skuld does**: Orchestration code written with effects is pure.
It *describes* what it needs (fetch user, generate UUID, write to
database) without performing any IO. Swap the handlers and the same
code runs entirely in memory:

```elixir
# The orchestration code - identical in production and tests
defcomp process_order(order_params) do
  user <- UserRepo.fetch_user!(order_params.user_id)
  id <- Fresh.fresh_uuid()
  price <- PricingService.calculate!(user, order_params.items)
  _ <- OrderRepo.create_order!(%{id: id, user_id: user.id, total: price})
  _ <- EventAccumulator.emit(%OrderPlaced{order_id: id, total: price})
  {:ok, id}
end
```

In tests, install pure handlers - an in-memory map for the repo, a
deterministic UUID generator, a stub for pricing. No database, no
network, no flakiness. Runs in microseconds.

This unlocks **property-based testing** for orchestration code: generate
hundreds of random inputs and verify business invariants hold, something
that's impractical when every test run hits real infrastructure.

See: [Testing Effectful Code](recipes/testing.md),
[Handler Stacks](recipes/handler-stacks.md)

### No more Mox boilerplate

**The pain**: Mox works for one mock. But when a single test needs
to stub three behaviours that interact, the setup is fragile and verbose.
Mocks are global (or per-process), making concurrent tests tricky.
And Mox can't help with property-based tests - you'd need stateful mock
coordination across hundreds of generated inputs.

**What Skuld does**: Handler swapping replaces Mox entirely for most
use cases. Handlers are scoped to the computation, not the process.
There's no global state to coordinate. Multiple effects compose
naturally - stubbing five things is as clean as stubbing one:

```elixir
process_order(%{user_id: "u1", items: items})
|> Port.with_test_handler(%{
  UserRepo.key(:fetch_user, "u1") => {:ok, test_user},
  PricingService.key(:calculate, {test_user, items}) => {:ok, 99_00}
})
|> Fresh.with_test_handler()
|> EventAccumulator.with_handler(output: &{&1, &2})
|> Throw.with_handler()
|> Comp.run!()
```

### Deterministic UUIDs, randomness, and time

**The pain**: Code that generates UUIDs or random values is
non-deterministic by nature. You either don't assert on the generated
values (leaving bugs hiding), inject generators awkwardly through
function parameters, or resort to process dictionary hacks.
Reproducing a bug that depends on a specific sequence of random values
is a guessing game.

**What Skuld does**: The Fresh and Random effects have deterministic
test handlers. Fresh generates UUID5 values from a namespace and
counter - the same test always produces the same UUIDs. Random accepts
a seed or a fixed sequence. Your tests are fully reproducible:

```elixir
# Always generates the same UUIDs in the same order
comp |> Fresh.with_test_handler(namespace: "my-test")

# Always produces the same random sequence
comp |> Random.with_seed_handler(seed: {1, 2, 3})

# Returns exactly these values, in order
comp |> Random.with_fixed_handler(values: [0.5, 0.1, 0.9])
```

## Automatic query batching

**The pain**: N+1 queries. You load a list of orders, then for each
order you load the user, then for each user you load their
subscription. Three levels of sequential queries that should be three
batched queries. DataLoader solves this for GraphQL, but it doesn't
generalise to arbitrary effectful code and doesn't compose with the
rest of your application logic.

**What Skuld does**: The `query` macro analyses data dependencies at
compile time and automatically batches independent operations. The
`deffetch` macro defines typed query contracts with executors that
receive batches of requests and return results in bulk:

```elixir
# Define a batchable query contract
defmodule UserQueries do
  use Skuld.Query.Contract

  deffetch get_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()}
end

# The executor receives ALL concurrent requests at once
defmodule UserQueries.Executor do
  @behaviour UserQueries.Executor

  def execute_get_user(requests) do
    ids = Enum.map(requests, fn {_ref, %{id: id}} -> id end)
    users = Repo.all(from u in User, where: u.id in ^ids)
    # Return %{ref => result} for each request
    Map.new(requests, fn {ref, %{id: id}} ->
      {ref, Enum.find(users, &(&1.id == id)) |> ok_or_not_found()}
    end)
  end
end
```

Independent queries within a `query` block run concurrently on
cooperative fibers and are batched automatically. Cross-batch caching
and within-batch deduplication come free via `Query.Cache`.

See: [Query & Batching](advanced/query-batching.md),
[Batch Data Loading](recipes/batch-loading.md)

## Long-running computations

**The pain**: Multi-step workflows that need to survive process
restarts. A payment flow that authorises, captures, and sends a
receipt. An onboarding wizard that collects information across multiple
screens. An LLM conversation loop that accumulates context over many
turns. If the process crashes mid-way, you need to reconstruct where
you were from external state - typically a state machine backed by a
database, or a chain of Oban jobs.

**What Skuld does**: EffectLogger records every effect request and
response as the computation runs. Serialise the log to JSON, store it
anywhere (database, Redis, S3), and resume the computation from where
it left off - even in a different process, on a different node, after
a restart. The resumed computation replays the log (skipping already-
completed effects) and continues from the suspension point:

```elixir
# Start a workflow - it yields when it needs external input
{suspend, _env} =
  onboarding_workflow(user_id)
  |> EffectLogger.with_logging()
  |> Yield.with_handler()
  |> Comp.run()

# Serialise and store the log from the suspension
log_json = Jason.encode!(suspend.data[EffectLogger])
store_workflow_state(workflow_id, log_json)

# Later (maybe after a restart), resume from the stored log
stored_log = load_workflow_state(workflow_id) |> Jason.decode!() |> EffectLogger.Log.deserialize()

{result, _env} =
  onboarding_workflow(user_id)
  |> EffectLogger.with_resume(stored_log, user_input)
  |> Yield.with_handler()
  |> Comp.run()
```

Loop marking and log pruning keep the serialised state bounded for
long-running conversations.

See: [EffectLogger](advanced/effect-logger.md),
[Durable Workflows](recipes/durable-workflows.md)

### LiveView multi-step operations

**The pain**: Phoenix LiveView has no built-in story for multi-step
effectful operations. A wizard that collects data across several
screens, runs validation at each step, and performs side effects at
the end requires manual state management and message passing. If the
operation can suspend and resume (waiting for user input between
steps), you're building a state machine by hand.

**What Skuld does**: AsyncComputation bridges effectful computations
into LiveView's process model. Start a computation, receive messages
when it yields or completes, resume it with user input:

```elixir
# In your LiveView
def handle_event("start_wizard", _params, socket) do
  {:ok, runner} = AsyncComputation.start(
    MyApp.Wizard.run(),
    tag: :wizard, caller: self()
  )
  {:noreply, assign(socket, runner: runner)}
end

def handle_info({AsyncComputation, :wizard, %ExternalSuspend{value: prompt}}, socket) do
  {:noreply, assign(socket, step: prompt)}
end

def handle_event("next_step", %{"answer" => answer}, socket) do
  AsyncComputation.resume(socket.assigns.runner, answer)
  {:noreply, socket}
end
```

See: [LiveView Integration](recipes/liveview.md)

## Clean architecture boundaries

**The pain**: You want hexagonal architecture - domain logic that
doesn't know about Ecto, HTTP clients, or specific vendor APIs. In
practice this means defining behaviours, writing adapters, and
threading implementations through function parameters or application
config. It works but it's tedious, and the plumbing obscures the
domain logic.

**What Skuld does**: Port.Contract defines typed boundaries between
your domain and infrastructure. Port.Adapter.Effectful bridges the other
direction - letting plain Elixir code call into effectful
implementations. The domain logic uses effects; the adapters are thin
modules that implement a behaviour:

```elixir
# The contract (shared boundary)
defmodule PaymentGateway do
  use Skuld.Effects.Port.Contract

  defport charge(amount :: Money.t(), card :: Card.t()) ::
    {:ok, Charge.t()} | {:error, term()}
end

# Production adapter
defmodule PaymentGateway.Stripe do
  @behaviour PaymentGateway.Plain
  def charge(amount, card), do: Stripe.API.create_charge(amount, card)
end

# Test adapter
defmodule PaymentGateway.InMemory do
  @behaviour PaymentGateway.Plain
  def charge(amount, _card), do: {:ok, %Charge{amount: amount, id: "ch_test"}}
end
```

The domain code calls `PaymentGateway.charge!(amount, card)` through
the effect system. No function parameter threading, no application
config lookups, no global state.

See: [Hexagonal Architecture](recipes/hexagonal-architecture.md),
[External Integration](effects/external-integration.md)

<!-- nav:footer:start -->

---

[< What Are Algebraic Effects?](what.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Getting Started >](getting-started.md)
<!-- nav:footer:end -->
