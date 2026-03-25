# Getting Started

<!-- nav:header:start -->
[< What Skuld Solves](pain-points.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Syntax In Depth >](syntax.md)
<!-- nav:header:end -->

This guide walks you through writing and running your first Skuld
computation. By the end, you'll understand the basic workflow: define a
computation, install handlers, and run it.

## Setup

Add Skuld to your dependencies in `mix.exs` (see
[Hex](https://hex.pm/packages/skuld) for the current version):

```elixir
def deps do
  [
    {:skuld, "~> x.y"}
  ]
end
```

In any module that uses Skuld, add:

```elixir
use Skuld.Syntax
```

This imports the `comp` macro, `defcomp`, and the core aliases you'll
need (`Skuld.Comp`, etc.).

## Your first computation

A **computation** is a lazy description of effectful work. It doesn't
execute when you define it - it's a value you can compose, wrap with
handlers, and eventually run.

The `comp` macro creates computations:

```elixir
computation = comp do
  count <- State.get()
  _ <- State.put(count + 1)
  count
end
```

This computation, when run, will:
1. Get the current state value and bind it to `count`
2. Update the state to `count + 1`
3. Return the original `count` value

But nothing has happened yet. `computation` is inert until you run it.

## Effectful binds and pure matches

Inside a `comp` block, there are two kinds of binding:

**`<-` (effectful bind)** runs an effect and binds its result:

```elixir
count <- State.get()       # run the State.get effect, bind result
name <- Reader.ask()       # run the Reader.ask effect, bind result
```

**`=` (pure match)** is ordinary Elixir pattern matching:

```elixir
%{name: name} = user       # pure destructuring, no effect
total = price * quantity    # pure calculation
```

The difference matters: `<-` sequences effectful operations (each one
runs after the previous completes), while `=` is just regular pattern
matching on values you already have.

## Auto-lifting

The last expression in a `comp` block is automatically lifted into a
computation. You don't need an explicit `return` or `Comp.pure`:

```elixir
comp do
  x <- State.get()
  x * 2                    # automatically becomes Comp.pure(x * 2)
end
```

This also means `if` without `else` works naturally:

```elixir
comp do
  _ <- if should_log?, do: Writer.tell("processing")
  # nil auto-lifted to Comp.pure(nil) when should_log? is false
  :done
end
```

Any plain (non-computation) value is auto-lifted wherever Skuld expects a
computation.

## Installing handlers

Effects don't do anything by themselves - they need handlers. A handler
tells the effect system how to respond to effect requests.

Install handlers by piping:

```elixir
computation
|> State.with_handler(0)           # State starts at 0
|> Comp.run!()
```

`State.with_handler(0)` wraps the computation with a State handler whose
initial value is `0`. The computation is still inert after this - adding
a handler just adds a wrapper.

## Running

`Comp.run!/1` executes a computation and returns the result:

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

The State started at `0`, so `State.get()` returned `0`, which became
the return value. The state was updated to `1`, but since we didn't ask
for it, it was discarded.

`Comp.run/1` returns both the result and the final environment, which is
useful when working with suspended computations:

```elixir
{result, env} = computation |> State.with_handler(0) |> Comp.run()
```

## Stacking handlers

A computation can use multiple effects. Install a handler for each one:

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

The pipeline reads naturally: start with the computation, wrap with
handlers, run. Handler order doesn't matter for correctness - each
handler manages its own effect independently.

## The output option

The result above is nested because each handler wraps the result. To get
cleaner output, use the `:output` option to transform the result when a
handler's scope ends:

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
returns the transformed result. This lets you extract handler state
(like the final State value or the accumulated Writer log) alongside
the computation's return value.

## Defining effectful functions with defcomp

Use `defcomp` to define named effectful functions:

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

`defcomp` wraps the function body in a `comp` block. The function returns
a computation that can be composed with other computations, wrapped with
handlers, and run.

Effectful functions compose naturally - `increment_twice/0` calls
`increment/0` twice using `<-`, and each call sequences properly.

## A complete example

Here's an end-to-end example showing the same computation running with
different handlers:

```elixir
defmodule TodoService do
  use Skuld.Syntax
  alias Skuld.Effects.{State, Reader, Writer}

  # A todo item
  defmodule Todo do
    defstruct [:id, :title, :done]
  end

  # Add a todo to the list
  defcomp add_todo(title) do
    todos <- State.get()
    id <- Reader.ask()     # use Reader to provide the next ID
    todo = %Todo{id: id, title: title, done: false}
    _ <- State.put([todo | todos])
    _ <- Writer.tell("Added: #{title}")
    todo
  end

  # Count completed todos
  defcomp count_done() do
    todos <- State.get()
    Enum.count(todos, & &1.done)
  end
end
```

Running with "production-style" handlers:

```elixir
alias Skuld.Comp

TodoService.add_todo("Write docs")
|> Reader.with_handler(1)                    # ID = 1
|> State.with_handler([],
     output: fn result, todos -> {result, todos} end)
|> Writer.with_handler([],
     output: fn result, log -> {result, log} end)
|> Comp.run!()
#=> {{%Todo{id: 1, title: "Write docs", done: false},
#     [%Todo{id: 1, title: "Write docs", done: false}]},
#    ["Added: Write docs"]}
```

Running the same code with different values:

```elixir
TodoService.add_todo("Ship it")
|> Reader.with_handler(42)                   # different ID
|> State.with_handler(existing_todos,
     output: fn result, todos -> {result, todos} end)
|> Writer.with_handler([],
     output: fn result, log -> {result, log} end)
|> Comp.run!()
```

Same function, different handlers, different behaviour. The
`TodoService` module has no idea where its IDs come from, how state is
stored, or what happens to its log messages. It just describes what it
needs using effects.

## What's next

- **[Syntax In Depth](syntax.md)** - The `else` clause for match failures,
  the `catch` clause for intercepting effects, clause grouping, and
  `defcomp` details
- **[Foundational Effects](effects/state-environment.md)** - State,
  Reader, Writer, error handling, persistence, and more
- **[Advanced Effects](advanced/yield.md)** - Coroutines, fibers,
  streaming, and serializable computations

<!-- nav:footer:start -->

---

[< What Skuld Solves](pain-points.md) | [Up: Introduction](../README.md) | [Index](../README.md) | [Syntax In Depth >](syntax.md)
<!-- nav:footer:end -->
