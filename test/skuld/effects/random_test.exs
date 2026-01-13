defmodule Skuld.Effects.RandomTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Random

  describe "with_handler (production)" do
    test "random() returns float in [0, 1)" do
      result =
        comp do
          f <- Random.random()
          f
        end
        |> Random.with_handler()
        |> Comp.run!()

      assert is_float(result)
      assert result >= 0.0
      assert result < 1.0
    end

    test "random_int/2 returns integer in range" do
      result =
        comp do
          i <- Random.random_int(1, 10)
          i
        end
        |> Random.with_handler()
        |> Comp.run!()

      assert is_integer(result)
      assert result >= 1
      assert result <= 10
    end

    test "random_int/2 works with negative ranges" do
      result =
        comp do
          i <- Random.random_int(-5, 5)
          i
        end
        |> Random.with_handler()
        |> Comp.run!()

      assert is_integer(result)
      assert result >= -5
      assert result <= 5
    end

    test "random_element/1 returns element from list" do
      list = [:a, :b, :c, :d]

      result =
        comp do
          elem <- Random.random_element(list)
          elem
        end
        |> Random.with_handler()
        |> Comp.run!()

      assert result in list
    end

    test "shuffle/1 returns list with same elements" do
      original = [1, 2, 3, 4, 5]

      result =
        comp do
          shuffled <- Random.shuffle(original)
          shuffled
        end
        |> Random.with_handler()
        |> Comp.run!()

      assert is_list(result)
      assert length(result) == length(original)
      assert Enum.sort(result) == Enum.sort(original)
    end

    test "shuffle/1 with empty list returns empty list" do
      result =
        comp do
          shuffled <- Random.shuffle([])
          shuffled
        end
        |> Random.with_handler()
        |> Comp.run!()

      assert result == []
    end

    test "multiple random calls produce different values (usually)" do
      # Run multiple times to check we're not getting constants
      results =
        for _ <- 1..10 do
          comp do
            f <- Random.random()
            f
          end
          |> Random.with_handler()
          |> Comp.run!()
        end

      # Should have some variety (extremely unlikely to get 10 identical values)
      assert length(Enum.uniq(results)) > 1
    end
  end

  describe "with_seed_handler (deterministic)" do
    test "same seed produces same sequence" do
      seed = {42, 123, 456}

      result1 =
        comp do
          a <- Random.random()
          b <- Random.random()
          c <- Random.random_int(1, 100)
          {a, b, c}
        end
        |> Random.with_seed_handler(seed: seed)
        |> Comp.run!()

      result2 =
        comp do
          a <- Random.random()
          b <- Random.random()
          c <- Random.random_int(1, 100)
          {a, b, c}
        end
        |> Random.with_seed_handler(seed: seed)
        |> Comp.run!()

      assert result1 == result2
    end

    test "different seeds produce different sequences" do
      result1 =
        comp do
          a <- Random.random()
          b <- Random.random()
          {a, b}
        end
        |> Random.with_seed_handler(seed: {1, 2, 3})
        |> Comp.run!()

      result2 =
        comp do
          a <- Random.random()
          b <- Random.random()
          {a, b}
        end
        |> Random.with_seed_handler(seed: {4, 5, 6})
        |> Comp.run!()

      assert result1 != result2
    end

    test "random() returns float in [0, 1)" do
      result =
        comp do
          f <- Random.random()
          f
        end
        |> Random.with_seed_handler(seed: {1, 2, 3})
        |> Comp.run!()

      assert is_float(result)
      assert result >= 0.0
      assert result < 1.0
    end

    test "random_int/2 returns integer in range" do
      result =
        comp do
          i <- Random.random_int(1, 10)
          i
        end
        |> Random.with_seed_handler(seed: {1, 2, 3})
        |> Comp.run!()

      assert is_integer(result)
      assert result >= 1
      assert result <= 10
    end

    test "random_element/1 returns element from list" do
      list = [:a, :b, :c, :d]

      result =
        comp do
          elem <- Random.random_element(list)
          elem
        end
        |> Random.with_seed_handler(seed: {1, 2, 3})
        |> Comp.run!()

      assert result in list
    end

    test "shuffle/1 is deterministic with same seed" do
      seed = {42, 42, 42}
      original = [1, 2, 3, 4, 5]

      result1 =
        comp do
          shuffled <- Random.shuffle(original)
          shuffled
        end
        |> Random.with_seed_handler(seed: seed)
        |> Comp.run!()

      result2 =
        comp do
          shuffled <- Random.shuffle(original)
          shuffled
        end
        |> Random.with_seed_handler(seed: seed)
        |> Comp.run!()

      assert result1 == result2
      assert Enum.sort(result1) == Enum.sort(original)
    end

    test "nested handlers are independent" do
      outer_seed = {1, 2, 3}
      inner_seed = {4, 5, 6}

      result =
        comp do
          outer1 <- Random.random()

          inner_result <-
            comp do
              inner1 <- Random.random()
              inner2 <- Random.random()
              {inner1, inner2}
            end
            |> Random.with_seed_handler(seed: inner_seed)

          outer2 <- Random.random()
          {outer1, inner_result, outer2}
        end
        |> Random.with_seed_handler(seed: outer_seed)
        |> Comp.run!()

      {outer1, {inner1, inner2}, outer2} = result

      # All values should be in valid range
      for f <- [outer1, inner1, inner2, outer2] do
        assert is_float(f)
        assert f >= 0.0 and f < 1.0
      end

      # Inner values should differ from outer (different seeds)
      assert {inner1, inner2} != {outer1, outer2}
    end
  end

  describe "with_fixed_handler (test scenarios)" do
    test "returns values from fixed sequence" do
      result =
        comp do
          a <- Random.random()
          b <- Random.random()
          c <- Random.random()
          {a, b, c}
        end
        |> Random.with_fixed_handler(values: [0.1, 0.5, 0.9])
        |> Comp.run!()

      assert result == {0.1, 0.5, 0.9}
    end

    test "cycles when sequence exhausted" do
      result =
        comp do
          a <- Random.random()
          b <- Random.random()
          c <- Random.random()
          d <- Random.random()
          {a, b, c, d}
        end
        |> Random.with_fixed_handler(values: [0.0, 1.0])
        |> Comp.run!()

      assert result == {0.0, 1.0, 0.0, 1.0}
    end

    test "random_int/2 uses fixed values to determine position in range" do
      # 0.0 -> min, 0.5 -> middle, ~1.0 -> max
      result =
        comp do
          a <- Random.random_int(1, 10)
          b <- Random.random_int(1, 10)
          {a, b}
        end
        |> Random.with_fixed_handler(values: [0.0, 0.9])
        |> Comp.run!()

      {a, b} = result
      # 0.0 maps to min
      assert a == 1
      # 0.9 maps to near max
      assert b >= 8
    end

    test "random_element/1 uses fixed values to select index" do
      result =
        comp do
          a <- Random.random_element([:first, :second, :third])
          b <- Random.random_element([:first, :second, :third])
          {a, b}
        end
        |> Random.with_fixed_handler(values: [0.0, 0.99])
        |> Comp.run!()

      {a, b} = result
      # 0.0 -> index 0
      assert a == :first
      # 0.99 -> index 2
      assert b == :third
    end

    test "shuffle/1 returns reversed list (deterministic behavior)" do
      result =
        comp do
          shuffled <- Random.shuffle([1, 2, 3, 4])
          shuffled
        end
        |> Random.with_fixed_handler(values: [0.5])
        |> Comp.run!()

      assert result == [4, 3, 2, 1]
    end

    test "default value is 0.5" do
      result =
        comp do
          f <- Random.random()
          f
        end
        |> Random.with_fixed_handler([])
        |> Comp.run!()

      assert result == 0.5
    end

    test "nested handlers are independent" do
      result =
        comp do
          outer1 <- Random.random()

          inner_result <-
            comp do
              inner1 <- Random.random()
              inner2 <- Random.random()
              {inner1, inner2}
            end
            |> Random.with_fixed_handler(values: [0.1, 0.2])

          outer2 <- Random.random()
          {outer1, inner_result, outer2}
        end
        |> Random.with_fixed_handler(values: [0.8, 0.9])
        |> Comp.run!()

      assert result == {0.8, {0.1, 0.2}, 0.9}
    end
  end

  describe "edge cases" do
    test "random_int with min == max returns that value" do
      result =
        comp do
          i <- Random.random_int(5, 5)
          i
        end
        |> Random.with_handler()
        |> Comp.run!()

      assert result == 5
    end

    test "random_element with single-element list returns that element" do
      result =
        comp do
          elem <- Random.random_element([:only])
          elem
        end
        |> Random.with_handler()
        |> Comp.run!()

      assert result == :only
    end

    test "shuffle with single-element list returns same list" do
      result =
        comp do
          shuffled <- Random.shuffle([:only])
          shuffled
        end
        |> Random.with_handler()
        |> Comp.run!()

      assert result == [:only]
    end
  end
end
