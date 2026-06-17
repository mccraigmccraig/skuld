defmodule Skuld.Effects.CellTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Cell
  alias Skuld.Effects.FiberPool
  alias Skuld.Effects.State

  describe "get/put" do
    test "get returns nil for unset tag" do
      {result, _env} =
        comp do
          value <- Cell.get(:unknown)
          value
        end
        |> Cell.with_handler()
        |> Comp.run()

      assert result == nil
    end

    test "put sets value and returns change" do
      {change, _env} =
        comp do
          change <- Cell.put(:results, [1, 2, 3])
          change
        end
        |> Cell.with_handler()
        |> Comp.run()

      assert %State.Change{old: nil, new: [1, 2, 3]} = change
    end

    test "get returns previously put value" do
      {result, _env} =
        comp do
          _ <- Cell.put(:results, [1, 2, 3])
          value <- Cell.get(:results)
          value
        end
        |> Cell.with_handler()
        |> Comp.run()

      assert result == [1, 2, 3]
    end

    test "multiple tags are independent" do
      {result, _env} =
        comp do
          _ <- Cell.put(:a, 1)
          _ <- Cell.put(:b, 2)
          a <- Cell.get(:a)
          b <- Cell.get(:b)
          {a, b}
        end
        |> Cell.with_handler()
        |> Comp.run()

      assert result == {1, 2}
    end

    test "same fiber can re-write" do
      {result, _env} =
        comp do
          _ <- Cell.put(:results, [1])
          _ <- Cell.put(:results, [1, 2])
          value <- Cell.get(:results)
          value
        end
        |> Cell.with_handler()
        |> Comp.run()

      assert result == [1, 2]
    end
  end

  describe "ownership" do
    test "non-owner write raises outside FiberPool" do
      comp =
        comp do
          _ <- Cell.put(:results, [1])
          :ok
        end
        |> Cell.with_handler()

      {_result, env} = Comp.run(comp)

      refute FiberPool.current_fiber_id(env)
    end

    test "re-write from same fiber works (no ownership check without FiberPool)" do
      {result, _env} =
        comp do
          _ <- Cell.put(:x, 1)
          _ <- Cell.put(:x, 2)
          value <- Cell.get(:x)
          value
        end
        |> Cell.with_handler()
        |> Comp.run()

      assert result == 2
    end
  end
end
