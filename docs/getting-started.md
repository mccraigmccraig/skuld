# Getting Started

<!-- nav:header:start -->
[< How Effects Work](what.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Syntax Guide >](syntax.md)
<!-- nav:header:end -->

This guide walks through your first Skuld computation — from definition
through handler installation to execution. By the end you'll understand
the basic pattern: define, install, run.

## Setup

Add Skuld to `mix.exs` (see [Hex](https://hex.pm/packages/skuld) for the
current version):

```elixir
def deps do
  [
    {:skuld, "~> 0.3"}
  ]
end
```

In any module that uses Skuld:

```elixir
use Skuld.Syntax
```

This imports the `comp` macro, `defcomp`, and `defcompp`.

## Your first computation

A **computation** is a description of effectful work. It doesn't execute
when defined — it's a value you compose, wrap with handlers, and
eventually run.

```elixir
computation = comp do
  count <- State.get()
  _ <- State.put(count + 1)
  count
end
```

This computation says: get the current state, increment it, return the
old value. But nothing has happened yet — `computation` is inert.

## `<-` vs `=`

Inside a `comp` block there are two kinds of binding:

**`<-` (effectful bind)** runs an effect and binds its result:

```elixir
count <- State.get()
name <- Reader.ask()
```

**`=` (pure match)** is ordinary Elixir pattern matching:

```elixir
%{name: name} = user
total = price * quantity
```

`<-` sequences operations; `=` destructures values you already have.

## Auto-lifting

The last expression in a `comp` block is automatically lifted into a
computation. No explicit `return` or `Comp.pure` needed:

```elixir
comp do
  x <- State.get()
  x * 2               # auto-lifted to Comp.pure(x * 2)
end
```

Any non-computation value is auto-lifted wherever a computation is
expected.

## Installing handlers

Effects don't do anything without handlers. A handler tells the effect
system how to respond to requests. Install handlers by piping:

```elixir
computation
|> State.with_handler(0)    # State starts at 0
|> Comp.run!()
#=> 0
```

`State.with_handler(0)` wraps the computation with a State handler whose
initial value is `0`. The computation is still inert — adding a handler
just adds a wrapper.

## Running

`Comp.run!/1` executes the computation and returns the result:

```elixir
comp do
  count <- State.get()
  _ <- State.put(count + 1)
  count
end
|> State.with_handler(0)
|> Comp.run!()
#=> 0
```

State started at `0`, `State.get()` returned `0`, which became the
return value. The state was updated to `1` but discarded.

`Comp.run/1` (without the bang) returns `{result, env}` for when you need
the final environment:

```elixir
{result, env} = computation |> State.with_handler(0) |> Comp.run()
```

## Stacking handlers

A computation can use multiple effects. Install a handler for each:

```elixir
comp do
  config <- Reader.ask()
  count <- State.get()
  _ <- State.put(count + 1)
  _ <- Writer.tell("processed item #{count}")
  {config, count}
end
|> Reader.with_handler(:my_config)
|> State.with_handler(0)
|> Writer.with_handler([])
|> Comp.run!()
#=> {{{:my_config, 0}, %{}}, []}
```

Each handler manages its own effect independently. Handler order doesn't
matter for correctness.

## Extracting handler state

The result above is nested because each handler wraps. Use the `:output`
option to extract handler state at the end of a scope:

```elixir
comp do
  config <- Reader.ask()
  count <- State.get()
  _ <- State.put(count + 1)
  _ <- Writer.tell("processed item #{count}")
  {config, count}
end
|> Reader.with_handler(:my_config)
|> State.with_handler(0, output: fn result, state -> {result, {:final_state, state}} end)
|> Writer.with_handler([], output: fn result, log -> {result, {:log, log}} end)
|> Comp.run!()
#=> {{{:my_config, 0}, {:final_state, 1}}, {:log, ["processed item 0"]}}
```

The `:output` function receives `(computation_result, handler_state)` and
returns the transformed result.

## Defining functions with defcomp

```elixir
defmodule Counter do
  use Skuld.Syntax

  defcomp increment() do
    count <- State.get()
    _ <- State.put(count + 1)
    count + 1
  end

  defcomp increment_by(n) do
    count <- State.get()
    _ <- State.put(count + n)
    count + n
  end

  defcomp increment_twice() do
    _ <- increment()
    increment()
  end
end
```

`defcomp` wraps the body in a `comp` block. These functions return
computations that compose, accept handlers, and run like any other.

## Production and test side by side

The defining feature of Skuld: the same domain code runs with different
handlers.

```elixir
defmodule TodoService do
  use Skuld.Syntax
  alias Skuld.Effects.{Reader, State, Writer}

  defmodule Todo do
    defstruct [:id, :title, :done]
  end

  defcomp add_todo(title) do
    todos <- State.get()
    id <- Reader.ask()
    todo = %Todo{id: id, title: title, done: false}
    _ <- State.put([todo | todos])
    _ <- Writer.tell("Added: #{title}")
    todo
  end
end
```

**Production handlers** — real values, side-effecting output:

```elixir
TodoService.add_todo("Write docs")
|> Reader.with_handler(1)
|> State.with_handler([], output: fn result, todos -> {result, todos} end)
|> Writer.with_handler([], output: fn result, log ->
  Enum.each(Enum.reverse(log), &Logger.info/1)
  result
end)
|> Comp.run!()
```

**Test handlers** — same code, same assertions, no side effects:

```elixir
# All handlers are pure — no Logger, no IO, no randomness
{_, {todo, todos}, log} =
  TodoService.add_todo("Write docs")
  |> Reader.with_handler(42)
  |> State.with_handler([], output: fn result, todos -> {result, todos} end)
  |> Writer.with_handler([], output: fn result, log -> {result, log} end)
  |> Comp.run!()

assert todo.id == 42
assert length(todos) == 1
assert log == ["Added: Write docs"]
```

Same `add_todo/1` function. In production the log goes to Logger; in
tests the log is a list you inspect. The domain code doesn't know which
it's running against.

## What's next

- **[Syntax Guide](syntax.md)** — `else`, `catch`, `defcomp` in detail
- **[How Effects Work](what.md)** — effects as first-class data, handler
  dispatch, scope, and why this enables more than just testing
- **[Testing](testing.md)** — deterministic handlers, property-based
  testing, in-memory Repo

<!-- nav:footer:start -->

---

[< How Effects Work](what.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Syntax Guide >](syntax.md)
<!-- nav:footer:end -->
