# Mox vs Skuld: an honest comparison

This document examines claims made in Skuld's documentation about Mox's
limitations. Some are valid, some are overstated, and some are wrong.
The goal is to understand where each approach genuinely shines so
documentation can make accurate claims.

## Claim 1: "Mox boilerplate for multiple stubs"

**The claim:** "Handler scoping replaces Mox — five stubs compose as
cleanly as one."

### Mox approach

```elixir
# Function under test calls 3 behaviours
defmodule OrderService do
  def place_order(params) do
    user = UserRepo.get!(params.user_id)
    inventory = InventoryRepo.check_stock(params.sku)

    if inventory.available >= params.qty do
      reservation = InventoryRepo.reserve(params.sku, params.qty)
      order = OrderRepo.insert!(%Order{user_id: user.id, sku: params.sku, qty: params.qty})
      Notifications.send(:order_placed, user, order)
      {:ok, order}
    else
      {:error, :insufficient_stock}
    end
  end
end

# Test setup with Mox stubs
test "place_order succeeds when stock available" do
  user = %User{id: "u1", name: "Alice"}
  order = %Order{id: "o1", user_id: "u1", sku: "WIDGET", qty: 2}

  stub(UserRepoMock, :get!, fn "u1" -> user end)
  stub(InventoryRepoMock, :check_stock, fn "WIDGET" -> %{available: 10} end)
  stub(InventoryRepoMock, :reserve, fn "WIDGET", 2 -> %{id: "r1"} end)
  stub(OrderRepoMock, :insert!, fn _changeset -> order end)
  stub(NotificationsMock, :send, fn :order_placed, _user, _order -> :ok end)

  assert {:ok, ^order} = OrderService.place_order(%{user_id: "u1", sku: "WIDGET", qty: 2})
end
```

### Skuld approach

```elixir
test "place_order succeeds when stock available" do
  user = %User{id: "u1", name: "Alice"}
  order = %Order{id: "o1", user_id: "u1", sku: "WIDGET", qty: 2}

  result =
    OrderWorkflow.place_order(%{user_id: "u1", sku: "WIDGET", qty: 2})
    |> Port.with_test_handler(%{
      UserRepo.EffectPort.key(:get, "u1") => {:ok, user},
      InventoryRepo.EffectPort.key(:check_stock, "WIDGET") => {:ok, %{available: 10}},
      InventoryRepo.EffectPort.key(:reserve, "WIDGET", 2) => {:ok, %{id: "r1"}},
      OrderRepo.EffectPort.key(:insert, _) => {:ok, order},
      Notifications.EffectPort.key(:send, :order_placed, _, _) => :ok
    })
    |> Throw.with_handler()
    |> Comp.run!()

  assert {:ok, ^order} = result
end
```

### Verdict: marginal difference

Both approaches are around 5-6 lines of stub setup. The Skuld version
is one expression (a map) rather than five separate calls, which is
slightly more compact but not transformatively so.

The Skuld map keys are `{module, function, args}` tuples, which is
arguably more scannable than separate `stub` calls. But this is a
matter of taste, not a fundamental limitation of Mox.

**Honest assessment: mild ergonomic improvement, not a pain point.**

---

## Claim 2: "Mox setup is fragile and verbose"

**The claim:** "When a single test needs to stub three behaviours that
interact, the setup is fragile and verbose."

### The `expect` vs `stub` distinction

Mox offers two tools:

- `expect/3` — verifies the function is called exactly N times, in
  order. If the implementation reorders two internal calls, the test
  breaks.
- `stub/3` — returns a value whenever called, any number of times, in
  any order. No verification of call count or order.

The "fragile" claim applies to `expect` — but `expect` is *designed*
to be order-sensitive. That's its feature, not its bug. If you don't
want order sensitivity, use `stub`.

### When ordering does matter

```elixir
# expect is fragile if the impl reorders calls
expect(RepoMock, :get!, fn "u1" -> user end)
expect(RepoMock, :insert!, fn _ -> order end)

# If the function starts doing insert! before get!, this breaks.
# But that's probably a bug you WANT to catch.
```

### When ordering doesn't matter

```elixir
# stub is not fragile — any order, any count
stub(RepoMock, :get!, fn "u1" -> user end)
stub(RepoMock, :insert!, fn _ -> order end)

# Function can call these in any order, any number of times.
```

### Skuld's map stubs

Skuld's `Port.with_test_handler` map is inherently unordered — like
`stub`, not `expect`. There's no built-in way to assert call order
(though `log: true` captures the sequence for post-hoc assertions).

### Verdict: not a real Mox problem

If you're finding Mox fragile, you're probably using `expect` where
`stub` would be more appropriate. The verbosity difference is marginal
(see Claim 1).

**Honest assessment: this is a "using the wrong tool" problem, not a
Mox limitation. Documentation should not claim Mox is fragile.**

---

## Claim 3: "Mocks are global (or per-process), making concurrent tests tricky"

**The claim:** "Mocks are global (or per-process), making concurrent
tests tricky."

### This is wrong for Mox

Mox expectations are per-process by default. Each test process gets its
own expectations, and `async: true` works fine. This is explicitly a
design goal of Mox — José Valim created it specifically to solve the
global mock problem.

```elixir
# These two tests can run concurrently with no interference
test "test A", %{} do
  stub(RepoMock, :get!, fn _ -> %User{name: "Alice"} end)
  assert OrderService.place_order(...) == ...
end

test "test B", %{} do
  stub(RepoMock, :get!, fn _ -> %User{name: "Bob"} end)
  assert OrderService.place_order(...) == ...
end
```

Mox also supports `allow/3` for sharing expectations across processes
(e.g. when the code under test spawns a Task), which handles the
multi-process case.

### Where Mox has a real concurrency limitation

The one edge case: if your code under test spawns a process that
outlives the test, and that process calls a mock, you need
`Mox.allow/3` — and the spawned process must be known at setup time.
This is genuinely awkward for fire-and-forget patterns.

### Skuld's approach

Skuld handlers live on the computation's continuation stack, not in
process dictionaries. A computation carries its handlers with it
regardless of which process runs it. This is cleaner for the
fire-and-forget case, but irrelevant for the common case (same
process).

### Verdict: the claim is wrong

Mox handles concurrent tests well. The documentation should not claim
otherwise.

**Honest assessment: remove this claim. Mox's per-process isolation is
fine for async tests. Skuld's handler-on-continuation model has a
theoretical advantage for multi-process scenarios, but this is rarely
the deciding factor.**

---

## Claim 4: "Mox can't help with property-based tests"

**The claim:** "Mox can't help with property-based tests — you'd need
stateful mock coordination across hundreds of generated inputs."

### The real issue: stateful interactions

Property-based tests generate random inputs. The function under test
makes multiple calls that must be *internally consistent* — data
written in call 3 must be retrievable in call 7.

```elixir
# Function under test
defmodule Onboarding do
  def register(params) do
    id = UUID.generate()
    user = Repo.insert!(%User{id: id, name: params.name})
    profile = Repo.insert!(%Profile{user_id: id, tier: :free})
    welcome = Repo.insert!(%Email{to: user.id, template: :welcome})
    Repo.get!(User, id)  # re-fetch to confirm
  end
end
```

### Mox with property tests: it works, but gets awkward

```elixir
property "register creates consistent user" do
  check all(name <- string(:alphanumeric, min_length: 1)) do
    # Need a shared store so insert! and get! see the same data
    {:ok, store} = Agent.start_link(fn -> %{} end)

    stub(RepoMock, :insert!, fn record ->
      Agent.update(store, &Map.put(&1, {record.__struct__, record.id}, record))
      record
    end)

    stub(RepoMock, :get!, fn schema, id ->
      Agent.get(store, &Map.fetch!(&1, {schema, id}))
    end)

    user = Onboarding.register(%{name: name})
    assert user.name == name

    Agent.stop(store)
  end
end
```

This works. But you've built an ad-hoc in-memory repository inside
your test setup, using an Agent for shared state. Every test that
needs stateful interactions builds its own version of this.

### Skuld with property tests: reusable in-memory handlers

```elixir
property "register creates consistent user" do
  check all(name <- string(:alphanumeric, min_length: 1)) do
    user =
      Onboarding.register(%{name: name})
      |> Repo.InMemory.with_handler(Repo.InMemory.new())
      |> Fresh.with_test_handler()
      |> Throw.with_handler()
      |> Comp.run!()

    assert user.name == name
  end
end
```

`Repo.InMemory` is a stateful in-memory Repo handler built on
`Port.with_stateful_handler`. State is a nested
`%{Schema => %{pk => struct}}` map that threads across Port calls,
giving read-after-write consistency for PK-based lookups within a
single computation. Non-PK reads use a `fallback_fn` — the adapter
never silently lies about record absence. It's written once and used
across all tests — no per-test Agent or closure hacks.

### The key difference

With Mox, stateful test doubles are ad-hoc — you build them per test
(or extract them into helpers, which amounts to building the same
in-memory implementation Skuld provides). With Skuld, the in-memory
handler is a first-class, reusable component that you write once.

### Verdict: valid, but the framing is wrong

Mox *can* do property-based tests. The claim that it "can't help" is
too strong. The real point is that stateful property tests with Mox
require building ad-hoc in-memory implementations (via Agents or
closures), while Skuld makes those implementations reusable and
composable.

**Honest assessment: reframe from "Mox can't" to "Mox requires
building ad-hoc stateful test doubles, which Skuld provides as
reusable handlers."**

---

## Claim 5: "15 sequential mock calls" / linear maintenance burden

**The claim:** "execute_clock_out would need mock expectations for 15
sequential calls, each returning values consistent with prior mock
returns. When the function adds step 16, every test's mock setup must
be updated."

This is the strongest argument for Skuld over Mox. Let's examine it
in detail.

### The problem: stateful call chains

Consider a function that performs a sequence of data access calls where
later calls depend on values from earlier calls:

```elixir
defmodule Payroll do
  def execute_clock_out(employee_id, timestamp) do
    employee = Repo.get!(Employee, employee_id)
    shift = Repo.get_by!(Shift, employee_id: employee_id, status: :active)
    rate = Repo.get!(PayRate, employee.pay_rate_id)
    policy = Repo.get!(OvertimePolicy, employee.overtime_policy_id)

    hours = Time.diff(timestamp, shift.started_at, :hour)
    overtime = max(0, hours - policy.threshold_hours)
    regular = hours - overtime

    pay =
      %Pay{
        employee_id: employee_id,
        shift_id: shift.id,
        regular_hours: regular,
        overtime_hours: overtime,
        regular_pay: Decimal.mult(regular, rate.hourly_rate),
        overtime_pay: Decimal.mult(overtime, Decimal.mult(rate.hourly_rate, policy.multiplier))
      }

    pay = Repo.insert!(pay)
    Repo.update!(Shift.changeset(shift, %{status: :completed, ended_at: timestamp}))

    {:ok, pay}
  end
end
```

### Mox test: the coupling problem

```elixir
test "clock out calculates overtime correctly" do
  employee = %Employee{id: "e1", pay_rate_id: "pr1", overtime_policy_id: "op1"}
  shift = %Shift{id: "s1", employee_id: "e1", status: :active, started_at: ~U[2024-01-01 08:00:00Z]}
  rate = %PayRate{id: "pr1", hourly_rate: Decimal.new("25.00")}
  policy = %OvertimePolicy{id: "op1", threshold_hours: 8, multiplier: Decimal.new("1.5")}

  # Every stub must return values consistent with what the function
  # will pass to subsequent calls
  stub(RepoMock, :get!, fn
    Employee, "e1" -> employee
    PayRate, "pr1" -> rate                # must match employee.pay_rate_id
    OvertimePolicy, "op1" -> policy       # must match employee.overtime_policy_id
  end)

  stub(RepoMock, :get_by!, fn
    Shift, [employee_id: "e1", status: :active] -> shift
  end)

  stub(RepoMock, :insert!, fn pay ->
    assert pay.regular_hours == 8
    assert pay.overtime_hours == 2
    %{pay | id: "p1"}
  end)

  stub(RepoMock, :update!, fn changeset ->
    Ecto.Changeset.apply_changes(changeset)
  end)

  assert {:ok, %Pay{overtime_hours: 2}} =
    Payroll.execute_clock_out("e1", ~U[2024-01-01 18:00:00Z])
end
```

Now the function gains a new requirement — check the employee's
department for holiday rates:

```elixir
# New line added to execute_clock_out:
department = Repo.get!(Department, employee.department_id)
holiday_rate = if department.holiday_schedule |> includes?(timestamp), do: 2.0, else: 1.0
```

**Every test must now:**
1. Add `department_id` to the employee fixture
2. Add a `Department` clause to the `get!` stub
3. Ensure the department's holiday schedule is consistent with the
   timestamp used in the test

This is the linear maintenance burden. Each new data access call
adds a fixture, a stub clause, and a consistency constraint to every
test of this function.

### Mox mitigation: extract a test helper

You can extract the fixture and stub setup into a shared helper:

```elixir
defmodule PayrollTestHelper do
  def setup_clock_out_stubs(opts \\ []) do
    employee = opts[:employee] || build(:employee)
    shift = opts[:shift] || build(:shift, employee_id: employee.id)
    rate = opts[:rate] || build(:pay_rate, id: employee.pay_rate_id)
    policy = opts[:policy] || build(:overtime_policy, id: employee.overtime_policy_id)
    department = opts[:department] || build(:department, id: employee.department_id)

    stub(RepoMock, :get!, fn
      Employee, id when id == employee.id -> employee
      PayRate, id when id == rate.id -> rate
      OvertimePolicy, id when id == policy.id -> policy
      Department, id when id == department.id -> department
    end)

    stub(RepoMock, :get_by!, fn
      Shift, [employee_id: eid, status: :active] when eid == employee.id -> shift
    end)

    stub(RepoMock, :insert!, fn record -> %{record | id: Ecto.UUID.generate()} end)
    stub(RepoMock, :update!, fn cs -> Ecto.Changeset.apply_changes(cs) end)

    %{employee: employee, shift: shift, rate: rate, policy: policy, department: department}
  end
end
```

This helps. When step 16 is added, you update one helper instead of
every test. But you're now maintaining an ad-hoc in-memory repository
simulation — a hand-rolled `get!` dispatcher that routes by schema and
ID, a fake `insert!` that assigns IDs, etc.

### Skuld test: the handler absorbs complexity

```elixir
test "clock out calculates overtime correctly" do
  # Seed the in-memory store with consistent data
  state = Repo.InMemory.new(
    seed: [
      %Employee{id: "e1", pay_rate_id: "pr1", overtime_policy_id: "op1"},
      %Shift{id: "s1", employee_id: "e1", status: :active, started_at: ~U[2024-01-01 08:00:00Z]},
      %PayRate{id: "pr1", hourly_rate: Decimal.new("25.00")},
      %OvertimePolicy{id: "op1", threshold_hours: 8, multiplier: Decimal.new("1.5")}
    ]
  )

  result =
    Payroll.execute_clock_out("e1", ~U[2024-01-01 18:00:00Z])
    |> Repo.InMemory.with_handler(state)
    |> Throw.with_handler()
    |> Comp.run!()

  assert {:ok, %Pay{overtime_hours: 2}} = result
end
```

When the function adds a Department lookup, you add one line to the
seed list. No stub routing logic to update, no helper function to
maintain. `Repo.InMemory` handles writes and PK-based reads (`get`,
`get!`) automatically — it's a working implementation backed by a map,
not a set of stubs. Writes are visible to subsequent PK reads within
the same computation. Non-PK reads (like `get_by`) require a
`fallback_fn` — the adapter never silently lies about record absence.

### Why the in-memory handler is fundamentally different from Mox stubs

The key insight is what each approach simulates:

- **Mox stubs simulate individual function calls.** Each stub returns
  a canned value. Cross-call consistency (data written in call 3 is
  readable in call 7) must be manually maintained by the test author.

- **Skuld in-memory handlers simulate the dependency's behaviour.**
  `Repo.InMemory` (built on `Port.with_stateful_handler`) maintains a
  `%{Schema => %{pk => struct}}` map across calls. PK-based consistency
  is automatic because the handler *is* a working implementation, backed
  by a map instead of a database.

This matters most when:
- The function makes many calls to the same dependency
- Later calls depend on data from earlier calls (reads-after-writes)
- The function is modified frequently, adding/removing/reordering calls

### The Mox test helper convergence

There's an ironic convergence: when Mox tests get complex enough, the
test helper you extract (like `PayrollTestHelper` above) starts looking
like an in-memory implementation. It has a fake data store, routing
logic for different schemas, and state management for writes.

At that point, the question becomes: why not write the in-memory
implementation once, properly, and reuse it everywhere? That's what
Skuld's handler model encourages.

### Verdict: valid, well-supported

This is a real, structural difference between the approaches. It's not
about boilerplate or syntax — it's about whether your test doubles
simulate individual calls (Mox) or simulate the dependency (Skuld
handlers).

**Honest assessment: the strongest argument for Skuld over Mox.
Documentation should focus on this case, not the marginal
ergonomic differences.**

---

## Claim 6: "Orchestration tests are slow"

**The claim:** "Swap handlers: same code runs in-memory with no DB, no
network."

### This is real but not Mox-specific

Mox tests are already fast — they don't hit the database. The speed
claim is about replacing *integration tests* (which do hit the DB) with
handler-swapped unit tests, not about replacing Mox tests.

The question is whether Mox unit tests are sufficient, or whether you
also need integration tests. Both Mox and Skuld let you avoid the
database in unit tests. The difference is that Skuld's in-memory
handlers provide higher-fidelity simulation (stateful, consistent),
potentially reducing the need for integration tests.

### Verdict: real, but applies to integration tests, not Mox

**Honest assessment: this is about replacing integration tests with
higher-fidelity unit tests, not about replacing Mox.**

---

## Summary: where each approach fits

| Scenario | Mox | Skuld | Winner |
|----------|-----|-------|--------|
| Simple function, 1-2 external calls | Fine | Fine | Tie |
| Multiple independent stubs | Slightly verbose | Slightly compact | Marginal Skuld |
| Order-sensitive verification | `expect` — designed for this | No built-in equivalent | Mox |
| Concurrent async tests | Per-process isolation, works well | Handler-on-continuation, works well | Tie |
| Stateful call chains (reads-after-writes) | Ad-hoc Agent/closure hacks | Reusable in-memory handlers | Skuld |
| Property-based tests with state | Possible but awkward | Natural fit | Skuld |
| Deep orchestration (10+ calls) | Linear stub maintenance | Seed data, handler absorbs calls | Skuld |
| Plain Elixir code (no effects) | Native fit | Requires Port contract | Mox |
| Incremental adoption | Zero infrastructure | Requires effect system | Mox |

### The honest pitch

Mox is great for simple mocking — isolated unit tests with 1-3
external calls where you want to verify specific interactions. Skuld's
advantage appears when:

1. **Functions have stateful interactions** — later calls depend on
   values from earlier calls, requiring consistent test doubles
2. **Functions are long and evolving** — 10+ external calls that
   change frequently, making stub maintenance expensive
3. **Property-based testing** — generated inputs need stateful
   responses, not canned values

If your codebase is mostly simple CRUD with thin orchestration, Mox
is simpler and requires no new infrastructure. If your orchestration
layer is thick, deeply interleaved, and under active development,
Skuld's handler model pays for itself.

### What the documentation should say

- **Removed:** "Mocks are global/per-process, making concurrent tests
  tricky" — this was wrong for Mox (done: pain-points.md updated)
- **Reframed:** "Mox boilerplate" → focus on reusable stateful test
  doubles vs per-test stub setup (done: pain-points.md updated)
- **Expanded:** the stateful call chain / property testing arguments
  now have real working implementations (`Port.with_stateful_handler`,
  `Repo.InMemory` with 3-stage dispatch) instead of aspirational examples
- **Be honest:** Mox is simpler for simple cases. Skuld's advantage
  is structural, not syntactic
