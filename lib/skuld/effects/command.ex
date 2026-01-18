defmodule Skuld.Effects.Command do
  @moduledoc """
  Effect for dispatching commands through a unified pipeline.

  Commands are structs representing mutations. The handler is a single function
  `(command -> computation)` that can route commands however it likes (pattern
  matching, map lookup, etc.). The returned computation can use other effects.

  ## Example

      defmodule MyCommandHandler do
        use Skuld.Syntax

        # Route via pattern matching
        def handle(%CreateTodo{title: title}) do
          comp do
            {:ok, todo} <- EctoPersist.insert(changeset(title))
            _ <- EventAccumulator.emit(%TodoCreated{id: todo.id})
            {:ok, todo}
          end
        end

        def handle(%DeleteTodo{id: id}) do
          comp do
            todo <- EctoPersist.get!(Todo, id)
            _ <- EctoPersist.delete(todo)
            _ <- EventAccumulator.emit(%TodoDeleted{id: id})
            :ok
          end
        end
      end

      # Use the Command effect
      comp do
        {:ok, todo} <- Command.execute(%CreateTodo{title: "Buy milk"})
        todo
      end
      |> Command.with_handler(&MyCommandHandler.handle/1)
      |> EctoPersist.with_handler(Repo)
      |> EventAccumulator.with_handler()
      |> Comp.run!()

  ## Handler Function

  The handler function has signature `(command -> computation)`. The returned
  computation can use any other effects installed in the pipeline. Routing
  is entirely up to the handler - use pattern matching, map lookup, or any
  other approach.
  """

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Execute, [:command])

  #############################################################################
  ## Types
  #############################################################################

  @typedoc "Function that takes a command and returns a computation"
  @type command_handler :: (struct() -> Types.computation())

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Execute a command through the effect system.

  The command will be passed to the installed handler function.

  ## Example

      Command.execute(%CreateTodo{title: "Buy milk"})
  """
  @spec execute(struct()) :: Types.computation()
  def execute(command) do
    Comp.effect(@sig, %Execute{command: command})
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a command handler for a computation.

  The handler is a function `(command -> computation)` that receives the
  command and returns a computation. The computation can use any other
  effects installed in the pipeline.

  ## Example

      my_comp
      |> Command.with_handler(&MyHandler.handle/1)
      |> Comp.run!()

      # Or with an anonymous function for dynamic routing:
      my_comp
      |> Command.with_handler(fn cmd ->
        handler = Map.fetch!(handlers, cmd.__struct__)
        handler.(cmd)
      end)
      |> Comp.run!()
  """
  @spec with_handler(Types.computation(), command_handler()) :: Types.computation()
  def with_handler(comp, handler_fn) when is_function(handler_fn, 1) do
    Comp.with_handler(comp, @sig, fn %Execute{command: command}, env, k ->
      # Call the handler function to get a computation
      command_computation = handler_fn.(command)
      # Run the computation with our continuation
      Comp.call(command_computation, env, k)
    end)
  end

  @doc """
  Install Command handler via catch clause syntax.

  Config is the handler function:

      catch
        Command -> &MyHandler.handle/1
  """
  def __handle__(comp, handler_fn) when is_function(handler_fn, 1),
    do: with_handler(comp, handler_fn)
end
