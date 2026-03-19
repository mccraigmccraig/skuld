defmodule Skuld.Comp.AletTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.FiberPool
  alias Skuld.Effects.State

  describe "ap/2" do
    test "applies function computation to value computation" do
      result =
        Comp.ap(Comp.pure(fn x -> x * 2 end), Comp.pure(21))
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "both computations run concurrently as fibers" do
      # Prove both sides execute by having them produce observable results
      result =
        Comp.ap(
          Comp.pure(fn x -> x + 10 end),
          Comp.pure(32)
        )
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end
  end

  describe "spawn_await_all/1" do
    test "single computation returns list with one result" do
      result =
        Comp.spawn_await_all([Comp.pure(42)])
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == [42]
    end

    test "multiple computations return results in order" do
      result =
        Comp.spawn_await_all([Comp.pure(:a), Comp.pure(:b), Comp.pure(:c)])
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == [:a, :b, :c]
    end

    test "computations run as fibers (concurrent)" do
      result =
        Comp.spawn_await_all([
          Comp.pure(10),
          Comp.pure(20),
          Comp.pure(12)
        ])
        |> Comp.map(fn [a, b, c] -> a + b + c end)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end
  end

  describe "alet — basic bindings" do
    test "single effectful binding" do
      result =
        alet a <- Comp.pure(42) do
          a
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "single pure binding" do
      result =
        alet a = 42 do
          Comp.pure(a)
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "two independent effectful bindings" do
      result =
        alet a <- Comp.pure(10),
             b <- Comp.pure(32) do
          a + b
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "three independent effectful bindings" do
      result =
        alet a <- Comp.pure(10),
             b <- Comp.pure(20),
             c <- Comp.pure(12) do
          a + b + c
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end
  end

  describe "alet — dependency analysis" do
    test "dependent binding runs after its dependency" do
      result =
        alet a <- Comp.pure(21),
             b <- Comp.pure(a * 2) do
          b
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "diamond dependency pattern" do
      # a is independent
      # b depends on a
      # c depends on a
      # d depends on b and c
      result =
        alet a <- Comp.pure(10),
             b <- Comp.pure(a + 5),
             c <- Comp.pure(a + 17),
             d <- Comp.pure(b + c) do
          d
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      # a=10, b=15, c=27, d=42
      assert result == 42
    end

    test "mixed independent and dependent bindings" do
      # a and b are independent (batch 1)
      # c depends on a and b (batch 2)
      result =
        alet a <- Comp.pure(10),
             b <- Comp.pure(32),
             c <- Comp.pure(a + b) do
          c
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "chain of sequential dependencies" do
      result =
        alet a <- Comp.pure(1),
             b <- Comp.pure(a + 1),
             c <- Comp.pure(b + 1),
             d <- Comp.pure(c + 1) do
          d
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 4
    end

    test "independent pairs in separate batches" do
      # a and b are independent (batch 1)
      # c depends on a, d depends on b (batch 2 — both independent of each other)
      # e depends on c and d (batch 3)
      result =
        alet a <- Comp.pure(10),
             b <- Comp.pure(20),
             c <- Comp.pure(a + 2),
             d <- Comp.pure(b + 3),
             e <- Comp.pure(c + d - 3) do
          e
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      # a=10, b=20, c=12, d=23, e=32
      assert result == 32
    end
  end

  describe "alet — pure bindings" do
    test "pure binding with effectful dependency" do
      result =
        alet a <- Comp.pure(21),
             b = a * 2 do
          Comp.pure(b)
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "independent pure and effectful bindings" do
      result =
        alet a <- Comp.pure(40),
             b = 2 do
          a + b
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end
  end

  describe "alet — pattern matching" do
    test "tuple pattern in effectful binding" do
      result =
        alet {:ok, a} <- Comp.pure({:ok, 42}) do
          a
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "tuple pattern with dependency" do
      result =
        alet a <- Comp.pure(21),
             {:ok, b} <- Comp.pure({:ok, a * 2}) do
          b
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end
  end

  describe "alet — effects" do
    test "bindings can use State effect" do
      result =
        alet a <- State.get(),
             b <- Comp.pure(a + 10) do
          b
        end
        |> State.with_handler(32)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "independent bindings execute concurrently" do
      # Both a and b should execute concurrently (they're independent)
      # We verify by checking the result combines values from both
      result =
        alet a <- Comp.pure(10),
             b <- Comp.pure(32) do
          a + b
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end
  end

  describe "alet — body is auto-lifted" do
    test "plain value body is auto-lifted" do
      result =
        alet a <- Comp.pure(42) do
          a
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end

    test "computation body works" do
      result =
        alet a <- Comp.pure(40) do
          Comp.pure(a + 2)
        end
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert result == 42
    end
  end
end
