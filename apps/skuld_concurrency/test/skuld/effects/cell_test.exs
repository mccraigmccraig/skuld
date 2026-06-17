defmodule Skuld.Effects.CellTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Cell
  alias Skuld.Effects.FiberPool
  alias Skuld.Effects.FiberYield
  alias Skuld.Effects.State

  defp wrap(comp) do
    comp
    |> Cell.with_handler()
    |> FiberYield.with_handler()
    |> FiberPool.with_handler()
  end

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

  describe "fiber integration" do
    test "writer fiber sets cell, main computation reads it after await" do
      {result, _env} =
        comp do
          h_w <-
            FiberPool.fiber(
              comp do
                _ <- Cell.put(:shared, 42)
                :written
              end
            )

          _ <- FiberPool.await!(h_w)
          value <- Cell.get(:shared)
          value
        end
        |> wrap()
        |> Comp.run()

      assert 42 = result
    end

    test "non-owner write raises inside FiberPool" do
      {result, _env} =
        comp do
          h_a <-
            FiberPool.fiber(
              comp do
                _ <- Cell.put(:owned, "A")
                :ok
              end
            )

          h_b <-
            FiberPool.fiber(
              comp do
                _ <- FiberPool.await!(h_a)
                Cell.put(:owned, "B")
              end
            )

          FiberPool.await_all([h_a, h_b])
        end
        |> wrap()
        |> Comp.run()

      assert [{:ok, :ok}, {:error, error}] = result
      assert %Skuld.Coroutine.Error{type: :exception} = error
      assert error.error.message =~ "Cell tag :owned is owned by fiber 0"
    end

    test "owner fiber can re-read its own writes" do
      {result, _env} =
        comp do
          h <-
            FiberPool.fiber(
              comp do
                _ <- Cell.put(:val, 99)
                v <- Cell.get(:val)
                v
              end
            )

          FiberPool.await!(h)
        end
        |> wrap()
        |> Comp.run()

      assert result == 99
    end
  end
end
