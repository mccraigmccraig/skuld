defmodule Skuld.Effects.CommandTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax
  alias Skuld.Comp
  alias Skuld.Effects.Command
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  # Test command structs
  defmodule CreateItem do
    defstruct [:name, :value]
  end

  defmodule UpdateItem do
    defstruct [:id, :name]
  end

  defmodule DeleteItem do
    defstruct [:id]
  end

  describe "Command.execute/1" do
    test "dispatches to handler and runs returned computation" do
      handler = fn
        %CreateItem{name: name, value: value} ->
          Comp.pure({:created, name, value})

        %UpdateItem{id: id, name: name} ->
          Comp.pure({:updated, id, name})
      end

      result =
        comp do
          r1 <- Command.execute(%CreateItem{name: "test", value: 42})
          r2 <- Command.execute(%UpdateItem{id: 1, name: "updated"})
          {r1, r2}
        end
        |> Command.with_handler(handler)
        |> Comp.run!()

      assert result == {{:created, "test", 42}, {:updated, 1, "updated"}}
    end

    test "handler computation can use other effects" do
      handler = fn %CreateItem{name: name, value: value} ->
        comp do
          count <- State.get()
          _ <- State.put(count + 1)
          {:created, name, value, count}
        end
      end

      result =
        comp do
          r1 <- Command.execute(%CreateItem{name: "first", value: 1})
          r2 <- Command.execute(%CreateItem{name: "second", value: 2})
          {r1, r2}
        end
        |> Command.with_handler(handler)
        |> State.with_handler(0)
        |> Comp.run!()

      assert result == {{:created, "first", 1, 0}, {:created, "second", 2, 1}}
    end

    test "handler not configured returns Throw with RuntimeError" do
      # When no handler is installed, Comp.effect raises because there's no handler
      # This gets converted to a Throw by the exception handling
      {result, _env} =
        comp do
          _ <- Command.execute(%CreateItem{name: "test", value: 1})
          :should_not_reach
        end
        |> Throw.with_handler()
        |> Comp.run()

      assert %Skuld.Comp.Throw{error: %{kind: :error, payload: %RuntimeError{}}} = result
    end

    test "handler can throw errors" do
      handler = fn %CreateItem{value: value} ->
        comp do
          _ <- if value < 0, do: Throw.throw({:invalid_value, value})
          {:created, value}
        end
      end

      result =
        comp do
          _ <- Command.execute(%CreateItem{name: "bad", value: -1})
          :should_not_reach
        catch
          {:invalid_value, v} -> {:caught_invalid, v}
        end
        |> Command.with_handler(handler)
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:caught_invalid, -1}
    end

    test "multiple commands in sequence" do
      handler = fn
        %CreateItem{name: name} ->
          comp do
            current <- State.get()
            _ <- State.put([name | current])
            :created
          end

        %DeleteItem{id: id} ->
          comp do
            current <- State.get()
            _ <- State.put(List.delete_at(current, id))
            :deleted
          end
      end

      {result, state} =
        comp do
          _ <- Command.execute(%CreateItem{name: "first", value: 1})
          _ <- Command.execute(%CreateItem{name: "second", value: 2})
          _ <- Command.execute(%CreateItem{name: "third", value: 3})
          _ <- Command.execute(%DeleteItem{id: 1})
          State.get()
        end
        |> Command.with_handler(handler)
        |> State.with_handler([], output: fn r, s -> {r, s} end)
        |> Comp.run!()

      # Items added in reverse (prepended), then "second" (index 1) deleted
      assert result == ["third", "first"]
      assert state == ["third", "first"]
    end

    test "handler can use map-based routing" do
      handlers = %{
        CreateItem => fn %CreateItem{name: n} -> Comp.pure({:created, n}) end,
        DeleteItem => fn %DeleteItem{id: id} -> Comp.pure({:deleted, id}) end
      }

      router = fn cmd ->
        handler = Map.fetch!(handlers, cmd.__struct__)
        handler.(cmd)
      end

      result =
        comp do
          r1 <- Command.execute(%CreateItem{name: "test", value: 1})
          r2 <- Command.execute(%DeleteItem{id: 42})
          {r1, r2}
        end
        |> Command.with_handler(router)
        |> Comp.run!()

      assert result == {{:created, "test"}, {:deleted, 42}}
    end
  end

  describe "Command handler scoping" do
    test "handlers are scoped and restored" do
      outer_handler = fn _ -> Comp.pure(:outer) end
      inner_handler = fn _ -> Comp.pure(:inner) end

      result =
        comp do
          r1 <- Command.execute(%CreateItem{name: "a", value: 1})

          r2 <-
            comp do
              Command.execute(%CreateItem{name: "b", value: 2})
            end
            |> Command.with_handler(inner_handler)

          r3 <- Command.execute(%CreateItem{name: "c", value: 3})
          {r1, r2, r3}
        end
        |> Command.with_handler(outer_handler)
        |> Comp.run!()

      assert result == {:outer, :inner, :outer}
    end
  end
end
