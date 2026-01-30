# Skuld Review: LLM Agent Perspective

An analysis of Skuld's suitability as a foundation for LLM-agent-built systems.

---

## Executive Summary

Skuld's algebraic effects provide **significant advantages for LLM agents** building and maintaining systems. The explicit effect boundaries, consistent patterns, and separation of pure logic from side effects align well with how LLMs reason about code. However, the paradigm shift from imperative Elixir and the complexity of some subsystems create learning challenges.

**Verdict**: Strongly recommended for LLM-agent development, with some caveats.

---

## Advantages for LLM Agents

### 1. Explicit Effect Boundaries Enable Reasoning

Traditional Elixir code has implicit side effects scattered throughout:

```elixir
# Traditional - side effects hidden everywhere
def process_order(order_id) do
  order = Repo.get!(Order, order_id)        # DB read (hidden)
  Logger.info("Processing #{order_id}")      # Logging (hidden)
  user = Repo.get!(User, order.user_id)      # DB read (hidden)
  EmailService.send(user.email, order)       # HTTP call (hidden)
  Repo.update!(order, %{status: :processed}) # DB write (hidden)
end
```

With Skuld, effects are explicit and trackable:

```elixir
# Skuld - effects are visible and explicit
defcomp process_order(order_id) do
  order <- Port.request!(OrderQueries, :get, %{id: order_id})
  _ <- Writer.tell({:info, "Processing #{order_id}"})
  user <- Port.request!(UserQueries, :get, %{id: order.user_id})
  _ <- Port.request!(EmailService, :send, %{to: user.email, order: order})
  Port.request!(OrderQueries, :update_status, %{id: order_id, status: :processed})
end
```

**LLM Advantage**: An agent can scan the code and immediately identify:
- What external systems are touched
- What order operations occur in
- What handlers need to be installed
- What to mock in tests

### 2. Consistent Patterns Reduce Generation Errors

Skuld enforces consistent patterns:

| Operation        | Pattern                              |
|------------------|--------------------------------------|
| Sequence effects | `x <- effect()`                      |
| Pure computation | `y = f(x)`                           |
| Install handler  | `\|> Effect.with_handler(config)`    |
| Test stub        | `\|> Port.with_test_handler(%{...})` |
| Error handling   | `catch {Throw, pattern} -> recovery` |

**LLM Advantage**: Once an agent learns the patterns, it can apply them mechanically. There's less "art" and more "engineering" - the consistent syntax means fewer creative decisions that could go wrong.

### 3. Pure Domain Logic is Easier to Reason About

Skuld separates:
- **What** (pure domain logic in computations)
- **How** (handlers provide implementation)

```elixir
# Domain logic - pure, testable, understandable
defcomp calculate_discount(user_id, cart) do
  user <- Port.request!(UserQueries, :get, %{id: user_id})
  loyalty_points <- Port.request!(LoyaltyService, :get_points, %{user_id: user_id})

  discount = case {user.tier, loyalty_points} do
    {:platinum, p} when p > 1000 -> 0.20
    {:gold, p} when p > 500 -> 0.15
    {:silver, _} -> 0.10
    _ -> 0.05
  end

  cart.total * (1 - discount)
end
```

**LLM Advantage**: The agent can understand the business logic without understanding database schemas, HTTP clients, or caching layers. It can reason about correctness at the domain level.

### 4. Test Generation is Mechanical

Given any Skuld computation, an LLM can generate tests by:
1. Identifying Port/effect calls
2. Creating stubs for each
3. Running with test handlers

```elixir
# LLM can mechanically generate this from the domain logic above
test "platinum user with 1500 points gets 20% discount" do
  comp = calculate_discount(1, %{total: 100.0})

  result = comp
  |> Port.with_test_handler(%{
    Port.key(UserQueries, :get, %{id: 1}) => {:ok, %{tier: :platinum}},
    Port.key(LoyaltyService, :get_points, %{user_id: 1}) => {:ok, 1500}
  })
  |> Throw.with_handler()
  |> Comp.run!()

  assert result == 80.0
end
```

**LLM Advantage**: Test generation becomes formulaic. The agent doesn't need to set up database fixtures, mock HTTP calls with complex libraries, or manage test state. Every effect has a corresponding test handler.

### 5. EffectLogger Enables Debugging and Replay

When something goes wrong, EffectLogger captures exactly what happened:

```elixir
# Run with logging
{result, log} = comp
|> EffectLogger.with_logging()
|> run_with_handlers()

# Log contains every effect invocation with inputs and outputs
# LLM can analyze: "The third Port call returned {:error, :timeout}"
```

**LLM Advantage**: Instead of parsing stack traces and log files, an agent can inspect structured effect logs. It can replay computations, identify exactly where failures occurred, and generate targeted fixes.

### 6. Refactoring is Safer

Pure computations can be refactored without fear of breaking side-effect ordering:

```elixir
# Before: sequential
defcomp get_user_data(id) do
  user <- Port.request!(UserQueries, :get, %{id: id})
  prefs <- Port.request!(PrefsQueries, :get, %{user_id: id})
  {user, prefs}
end

# After: parallel (LLM can safely make this change)
defcomp get_user_data(id) do
  {user, prefs} <- Parallel.all([
    Port.request!(UserQueries, :get, %{id: id}),
    Port.request!(PrefsQueries, :get, %{user_id: id})
  ])
  {user, prefs}
end
```

**LLM Advantage**: The effect system makes dependencies explicit. An agent can see that these two calls are independent and safely parallelize them. With implicit side effects, this transformation would be risky.

### 7. Composition Without Hidden Interactions

Effects compose predictably:

```elixir
# Combining multiple computations
defcomp complex_workflow(data) do
  validated <- validate(data)           # May throw
  enriched <- enrich(validated)         # Uses Port
  result <- process(enriched)           # Uses State
  _ <- notify(result)                   # Uses Port
  result
end
```

**LLM Advantage**: Each sub-computation's effects are handled by the same handlers. There's no hidden state sharing, no implicit database transactions spanning calls, no surprising interactions. The agent can reason about each piece independently.

---

## Disadvantages for LLM Agents

### 1. Paradigm Shift from Training Data

Most Elixir code in LLM training data is imperative:

```elixir
# What LLMs have seen millions of times
def create_user(attrs) do
  %User{}
  |> User.changeset(attrs)
  |> Repo.insert()
end
```

Skuld requires a mental model shift:

```elixir
# What LLMs have seen far less
defcomp create_user(attrs) do
  changeset = User.changeset(%User{}, attrs)
  ChangesetPersist.insert(changeset)
end
```

**LLM Disadvantage**: Agents may instinctively generate imperative code and need correction. The monadic bind (`<-`) pattern is less common in training data than direct function calls.

### 2. Handler Installation is Error-Prone

Every computation needs correct handlers:

```elixir
# Missing Reader handler - will crash at runtime
comp
|> State.with_handler(0)
|> Throw.with_handler()
# |> Reader.with_handler(config)  # Forgot this!
|> Comp.run!()
```

**LLM Disadvantage**: No compile-time checking means agents can generate code that crashes at runtime due to missing handlers. The error messages ("key not found") don't clearly indicate "you forgot to install the Reader handler".

### 3. Handler Order Can Matter in Specific Cases

Handler order matters in two specific scenarios:

**Wrapping handlers (e.g., EffectLogger):**
```elixir
# Correct - EffectLogger sees all effects (installed innermost)
comp
|> EffectLogger.with_logging()   # Wraps all subsequently installed handlers
|> State.with_handler(0)
|> Port.with_handler(registry)
|> Throw.with_handler()

# Wrong - EffectLogger only sees Throw effects
comp
|> State.with_handler(0)
|> Port.with_handler(registry)
|> EffectLogger.with_logging()   # Only wraps Throw handler
|> Throw.with_handler()
```

**Handlers with `:output` transformations:**
```elixir
# Output transformations compose in installation order
comp
|> State.with_handler(0, output: fn result, state -> {result, state} end)
|> Writer.with_handler([], output: fn {r, s}, log -> {r, s, log} end)
```

**LLM Disadvantage**: Agents need to understand which handlers wrap others and how output transformations compose. Most handlers are order-independent, but the exceptions are subtle.

### 4. Async Complexity is High

The Async effect has many concepts:
- Boundaries (structured concurrency scopes)
- Fibers (cooperative, same process)
- Tasks (parallel, separate process)
- Handles (TaskHandle vs FiberHandle)
- Scheduler (fair FIFO scheduling)
- Timeouts (await_with_timeout, TimerTarget)

```elixir
# Lots of concepts to juggle
defcomp complex_async() do
  result <- Async.boundary(comp do
    h1 <- Async.fiber(work1())      # Cooperative
    h2 <- Async.async(work2())       # Parallel
    timer = TimerTarget.new(5000)

    {winner, result} <- Async.await_any_raw([
      TaskTarget.new(h2.task),
      FiberTarget.new(h1.fiber_id),
      timer
    ])

    case winner do
      {:timer, _} -> :timeout
      _ -> result
    end
  end)
  result
end
```

**LLM Disadvantage**: The complexity creates many opportunities for bugs. Agents may confuse fibers and tasks, forget boundaries, mishandle timeouts, or create unawaited work that gets killed.

### 5. Limited Training Examples

Skuld is a niche library. LLMs have seen:
- Millions of Ecto examples
- Millions of Phoenix examples
- Thousands of GenServer examples
- Maybe dozens of Skuld examples

**LLM Disadvantage**: Agents can't rely on pattern matching against training data. They need to reason from documentation and first principles, which is harder and more error-prone.

### 6. Suspended Computations: Opaque Resume, But Transparent History

When a computation suspends (Yield), the `resume` function is opaque:

```elixir
%Suspend{
  value: :prompt,
  resume: #Function<...>,  # Can't inspect what this will do
  data: %{...}
}
```

However, when using EffectLogger, the `data` field contains a complete structured log:

```elixir
%Suspend{
  value: :prompt,
  resume: #Function<...>,
  data: %{
    effect_log: [
      %{sig: Port, data: %{mod: UserQueries, name: :get, params: %{id: 1}}, value: {:ok, %{...}}},
      %{sig: State, data: %{op: :get}, value: %{counter: 5}},
      # ... complete history of all effects
    ],
    checkpoints: %{...}  # State snapshots at marked points
  }
}
```

**Nuanced Assessment**: While the `resume` closure itself is opaque, EffectLogger provides *superior* transparency compared to typical debugging:
- Complete history of what happened (not just current stack)
- Inputs and outputs of every effect call
- State checkpoints for inspection
- Ability to replay deterministically

This is actually an **advantage** for LLM agents - structured effect logs are easier to analyze than stack traces and scattered log files.

### 7. No Static Effect Tracking

There's no way to declare or check effects statically:

```elixir
# Hypothetical (doesn't exist)
@effects [State, Reader, Throw]
defcomp my_function() do
  ...
end
```

**LLM Disadvantage**: Agents must read the entire function body to understand what effects are used. They can't rely on type signatures or declarations. This makes large codebases harder to navigate.

---

## Recommendations for LLM-Agent Usage

### Do

1. **Start with simple effects** - State, Reader, Throw, Port
2. **Use Port for all I/O** - Creates clean test boundaries
3. **Always install Throw.with_handler()** - Catches errors cleanly
4. **Use with_sequential_handler for Async tests** - Simpler debugging
5. **Leverage EffectLogger for debugging** - Structured effect traces
6. **Create effect "bundles"** - Standard handler stacks for common scenarios

### Don't

1. **Don't mix paradigms** - Either use effects everywhere or nowhere
2. **Don't use Async.fiber for simple parallelism** - Use Parallel.all instead
3. **Don't forget boundaries** - Unawaited work gets killed
4. **Don't rely on handler order** - Be explicit about what you need

### Patterns for LLM Agents

**Standard handler installation:**
```elixir
def run_with_standard_handlers(comp, opts \\ []) do
  comp
  |> Port.with_handler(opts[:port_registry] || %{})
  |> State.with_handler(opts[:initial_state] || %{})
  |> Reader.with_handler(opts[:config] || %{})
  |> Writer.with_handler([])
  |> Throw.with_handler()
  |> Comp.run()
end
```

**Test helper:**
```elixir
def run_with_test_handlers(comp, stubs) do
  comp
  |> Port.with_test_handler(stubs)
  |> State.with_handler(%{})
  |> Throw.with_handler()
  |> Comp.run!()
end
```

---

## Conclusion

### For LLM Agents, Skuld Provides:

| Benefit                    | Impact                                             |
|----------------------------|----------------------------------------------------|
| Explicit effects           | High - enables reasoning about side effects        |
| Consistent patterns        | High - reduces generation errors                   |
| Pure domain logic          | High - easier to understand and refactor           |
| Mechanical test generation | High - test stubs follow patterns                  |
| Effect logging             | High - structured history superior to stack traces |
| Composition                | Medium - predictable combining                     |

### Challenges:

| Challenge            | Severity                         |
|----------------------|----------------------------------|
| Paradigm shift       | Medium - requires learning       |
| Handler installation | Medium - error-prone             |
| Async complexity     | High - many concepts             |
| Limited examples     | Medium - less to learn from      |
| No static tracking   | Low - manageable with discipline |

### Final Assessment

**Skuld is well-suited for LLM-agent development** because it makes implicit things explicit. Side effects become visible. Dependencies become trackable. Tests become mechanical.

The main risk is the paradigm shift. An LLM agent needs to be "taught" the effect patterns, either through examples in context or fine-tuning. Once learned, the patterns are consistent and mechanical - exactly what LLM agents excel at.

**Recommendation**: Use Skuld for new systems where LLM agents will be primary maintainers. The upfront learning investment pays off in more reliable code generation and easier automated maintenance.

**Rating for LLM-Agent Use**: 8.5/10 - Strong fit with manageable learning curve.
