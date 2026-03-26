# Durable Workflows

<!-- nav:header:start -->
[< LiveView Integration](liveview.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [Data Pipelines >](data-pipelines.md)
<!-- nav:header:end -->

EffectLogger turns computations into durable workflows that survive
process restarts, server reboots, and code deployments. This is
Temporal-style durable execution as a library primitive.

## The pattern

1. Write a computation that yields at interaction/wait points
2. Run with `EffectLogger.with_logging()` to capture the effect log
3. When the computation suspends, serialize and persist the log
4. Later, cold-resume from the persisted log with a new value

## Basic workflow: approval flow

```elixir
defmodule ApprovalWorkflow do
  use Skuld.Syntax

  defcomp run(request) do
    # Step 1: validate the request
    validated <- validate(request)

    # Step 2: yield for manager approval
    approval <- Yield.yield(%{
      type: :approval_needed,
      request: validated,
      approver: validated.manager_id
    })

    case approval do
      :approved ->
        # Step 3: execute the approved action
        result <- execute(validated)
        _ <- EventAccumulator.emit(%RequestApproved{
          request_id: validated.id
        })
        {:ok, result}

      :rejected ->
        _ <- EventAccumulator.emit(%RequestRejected{
          request_id: validated.id
        })
        {:rejected, validated.id}
    end
  end
end
```

### Starting the workflow

```elixir
alias Skuld.Effects.EffectLogger
alias Skuld.Effects.EffectLogger.Log

{suspended, env} =
  ApprovalWorkflow.run(request)
  |> EffectLogger.with_logging()
  |> Yield.with_handler()
  |> State.with_handler(initial_state)
  |> EventAccumulator.with_handler(output: fn r, e -> {r, e} end)
  |> Throw.with_handler()
  |> Comp.run()

# suspended.value is %{type: :approval_needed, ...}

# Persist the log
log = EffectLogger.get_log(env) |> Log.finalize()
json = Jason.encode!(log)
Repo.insert!(%WorkflowState{
  workflow_id: request.id,
  log: json,
  status: :awaiting_approval
})
```

### Resuming after approval

```elixir
# Load the persisted log
workflow = Repo.get!(WorkflowState, request_id)
cold_log = workflow.log |> Jason.decode!() |> Log.from_json()

# Resume with the approval decision
{result, env} =
  ApprovalWorkflow.run(request)               # same source code
  |> EffectLogger.with_resume(cold_log, :approved)
  |> Yield.with_handler()
  |> State.with_handler(nil)                  # ignored - restored from log
  |> EventAccumulator.with_handler(output: fn r, e -> {r, e} end)
  |> Throw.with_handler()
  |> Comp.run()

# result is {:ok, execution_result}
```

## Long-running loops: LLM conversations

For workflows with multiple interaction cycles, use `mark_loop` to
keep the log bounded:

```elixir
defmodule ConversationWorkflow do
  use Skuld.Syntax

  defcomp run() do
    _ <- EffectLogger.mark_loop(ConversationLoop)
    history <- State.get()

    # Yield for user input
    user_msg <- Yield.yield(%{
      type: :user_input,
      history: history
    })

    # Call LLM (via Port)
    response <- LLM.chat!(history ++ [%{role: :user, content: user_msg}])

    # Update conversation history
    _ <- State.put(history ++ [
      %{role: :user, content: user_msg},
      %{role: :assistant, content: response}
    ])

    # Check if conversation should end
    case response do
      %{done: true} -> {:done, response}
      _ -> run()  # loop for next turn
    end
  end
end
```

Each cycle: suspend -> serialize -> persist -> (user responds) ->
deserialize -> resume -> next cycle. The `mark_loop` keeps the log
O(current iteration) regardless of conversation length.

## Surviving deployments

When code changes between suspend and resume, EffectLogger can handle
divergence:

```elixir
|> EffectLogger.with_resume(cold_log, value, allow_divergence: true)
```

With `allow_divergence`:
- Completed effects replay from logged values (fast-forward)
- If the code path diverges from the log (new effects, removed
  effects), execution continues fresh from the divergence point
- Failed/discarded effects re-execute

This means you can deploy bug fixes and the workflow picks up from
where it left off, re-executing any changed logic.

## Persistence strategies

### Database

```elixir
# Store as JSON in a text/jsonb column
Repo.insert!(%Workflow{
  id: workflow_id,
  log: Jason.encode!(Log.finalize(log)),
  status: :suspended,
  suspended_at: DateTime.utc_now()
})

# Resume
workflow = Repo.get!(Workflow, workflow_id)
cold_log = workflow.log |> Jason.decode!() |> Log.from_json()
```

### Message queue

```elixir
# Publish suspended workflow for async processing
Broadway.produce(Jason.encode!(%{
  workflow_id: id,
  log: Log.finalize(log),
  resume_value: value
}))
```

### File system (development)

```elixir
File.write!("workflows/#{id}.json", Jason.encode!(Log.finalize(log)))
cold_log = "workflows/#{id}.json"
  |> File.read!()
  |> Jason.decode!()
  |> Log.from_json()
```

## Comparison with Temporal.io

| Aspect | Skuld EffectLogger | Temporal.io |
|--------|-------------------|-------------|
| Infrastructure | Library (no server) | Server cluster required |
| Language | Elixir only | Multi-language SDKs |
| Serialization | JSON log of effects | Protobuf event history |
| Resume mechanism | Source replay + log | Worker polling + replay |
| Activities | Effects (Port, Transaction, etc.) | RPC-dispatched activities |
| Composition | Algebraic effect stacking | Workflow/activity split |
| Deployment | Your app process | Separate service |

Skuld is much lighter-weight: no infrastructure, no RPC, and full
algebraic effect composition. Temporal is more mature for production
distributed workflows with built-in retry policies, visibility, and
multi-language support.

<!-- nav:footer:start -->

---

[< LiveView Integration](liveview.md) | [Up: Patterns & Recipes](testing.md) | [Index](../../README.md) | [Data Pipelines >](data-pipelines.md)
<!-- nav:footer:end -->
