defmodule Skuld.Effects.FxFasterListTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.FxFasterList
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield

  describe "fx_map" do
    test "maps effectful function over empty list" do
      comp =
        FxFasterList.fx_map([], fn x -> Comp.pure(x * 2) end)

      assert Comp.run!(comp) == []
    end

    test "maps effectful function over list" do
      comp =
        FxFasterList.fx_map([1, 2, 3], fn x -> Comp.pure(x * 2) end)

      assert Comp.run!(comp) == [2, 4, 6]
    end

    test "maps with stateful effects" do
      comp =
        FxFasterList.fx_map([1, 2, 3], fn x ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              Comp.pure({x, count})
            end)
          end)
        end)
        |> State.with_handler(0)

      assert Comp.run!(comp) == [{1, 0}, {2, 1}, {3, 2}]
    end
  end

  describe "fx_reduce" do
    test "reduces empty list to initial value" do
      comp =
        FxFasterList.fx_reduce([], 0, fn x, acc -> Comp.pure(acc + x) end)

      assert Comp.run!(comp) == 0
    end

    test "reduces list with effectful function" do
      comp =
        FxFasterList.fx_reduce([1, 2, 3, 4], 0, fn x, acc -> Comp.pure(acc + x) end)

      assert Comp.run!(comp) == 10
    end

    test "reduces with stateful effects" do
      comp =
        FxFasterList.fx_reduce([1, 2, 3], [], fn x, acc ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              Comp.pure([{x, count} | acc])
            end)
          end)
        end)
        |> State.with_handler(0)

      assert Comp.run!(comp) == [{3, 2}, {2, 1}, {1, 0}]
    end
  end

  describe "fx_each" do
    test "executes effectful function for each element" do
      comp =
        Comp.bind(
          FxFasterList.fx_each([1, 2, 3], fn x ->
            Comp.bind(State.get(), fn acc ->
              State.put([x | acc])
            end)
          end),
          fn :ok ->
            State.get()
          end
        )
        |> State.with_handler([])

      assert Comp.run!(comp) == [3, 2, 1]
    end

    test "returns :ok" do
      comp =
        FxFasterList.fx_each([1, 2, 3], fn _ -> Comp.pure(:ignored) end)

      assert Comp.run!(comp) == :ok
    end

    test "works with range" do
      comp =
        Comp.bind(
          FxFasterList.fx_each(1..5, fn _ ->
            Comp.bind(State.get(), fn n ->
              State.put(n + 1)
            end)
          end),
          fn :ok ->
            State.get()
          end
        )
        |> State.with_handler(0)

      assert Comp.run!(comp) == 5
    end
  end

  describe "fx_filter" do
    test "filters empty list" do
      comp =
        FxFasterList.fx_filter([], fn x -> Comp.pure(x > 0) end)

      assert Comp.run!(comp) == []
    end

    test "filters list with pure predicate" do
      comp =
        FxFasterList.fx_filter([1, 2, 3, 4, 5], fn x -> Comp.pure(rem(x, 2) == 0) end)

      assert Comp.run!(comp) == [2, 4]
    end

    test "filters with stateful predicate" do
      # Keep only elements where state counter is even
      comp =
        FxFasterList.fx_filter([1, 2, 3, 4, 5], fn _x ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              Comp.pure(rem(count, 2) == 0)
            end)
          end)
        end)
        |> State.with_handler(0)

      # count=0 (even) -> keep 1
      # count=1 (odd) -> drop 2
      # count=2 (even) -> keep 3
      # count=3 (odd) -> drop 4
      # count=4 (even) -> keep 5
      assert Comp.run!(comp) == [1, 3, 5]
    end
  end

  # ============================================================
  # Control Effect Tests - Throw
  # ============================================================

  describe "fx_map with Throw" do
    test "throw in middle of list short-circuits" do
      comp =
        FxFasterList.fx_map([1, 2, 3, 4, 5], fn x ->
          if x == 3 do
            Throw.throw({:error, :hit_three})
          else
            Comp.pure(x * 2)
          end
        end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %Comp.Throw{error: {:error, :hit_three}} = result
    end

    test "throw preserves state up to failure point" do
      comp =
        FxFasterList.fx_map([1, 2, 3, 4, 5], fn x ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              if x == 3 do
                Throw.throw({:error, :hit_three})
              else
                Comp.pure(x * 2)
              end
            end)
          end)
        end)
        |> State.with_handler(0, output: fn result, state -> {result, state} end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      # State should be 3 (processed 1, 2, 3 before throw on 3)
      assert {%Comp.Throw{error: {:error, :hit_three}}, 3} = result
    end

    test "no throw returns normal result" do
      comp =
        FxFasterList.fx_map([1, 2, 3], fn x -> Comp.pure(x * 2) end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert result == [2, 4, 6]
    end

    test "try_catch wraps result" do
      comp =
        Throw.try_catch(
          FxFasterList.fx_map([1, 2, 3], fn x ->
            if x == 2 do
              Throw.throw(:hit_two)
            else
              Comp.pure(x * 2)
            end
          end)
        )
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert {:error, :hit_two} = result
    end
  end

  describe "fx_reduce with Throw" do
    test "throw in reducer short-circuits" do
      comp =
        FxFasterList.fx_reduce([1, 2, 3, 4, 5], 0, fn x, acc ->
          if x == 3 do
            Throw.throw({:error, :hit_three, acc})
          else
            Comp.pure(acc + x)
          end
        end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      # acc was 3 (1+2) when we hit 3
      assert %Comp.Throw{error: {:error, :hit_three, 3}} = result
    end
  end

  describe "fx_each with Throw" do
    test "throw in each short-circuits" do
      comp =
        Comp.bind(
          FxFasterList.fx_each([1, 2, 3, 4, 5], fn x ->
            Comp.bind(State.get(), fn acc ->
              Comp.bind(State.put([x | acc]), fn _ ->
                if x == 3 do
                  Throw.throw(:hit_three)
                else
                  Comp.pure(:ok)
                end
              end)
            end)
          end),
          fn :ok -> State.get() end
        )
        |> State.with_handler([])
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %Comp.Throw{error: :hit_three} = result
    end
  end

  describe "fx_filter with Throw" do
    test "throw in predicate short-circuits" do
      comp =
        FxFasterList.fx_filter([1, 2, 3, 4, 5], fn x ->
          if x == 3 do
            Throw.throw(:hit_three)
          else
            Comp.pure(rem(x, 2) == 0)
          end
        end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %Comp.Throw{error: :hit_three} = result
    end
  end

  # ============================================================
  # Control Effect Tests - Yield (Suspend/Resume)
  # FxFasterList has LIMITED suspend support - it suspends but loses context
  # ============================================================

  describe "fx_map with Yield" do
    test "yield suspends but cannot resume to continue list (loses context)" do
      comp =
        FxFasterList.fx_map([1, 2, 3, 4, 5], fn x ->
          Comp.bind(Yield.yield({:processing, x}), fn _ ->
            Comp.pure(x * 2)
          end)
        end)
        |> Yield.with_handler()

      # First run should yield with first element
      {%Comp.Suspend{value: {:processing, 1}, resume: r1}, _e1} = Comp.run(comp)

      # Resume - but FxFasterList doesn't preserve the list iteration context!
      # It just returns the single element's result, not the full list
      {result, _env} = r1.(:resumed)
      # FxFasterList only returns the result of the first element, not the full list
      assert result == 2
    end
  end

  describe "fx_each with Yield" do
    test "yield suspends but loses remaining elements on resume" do
      comp =
        FxFasterList.fx_each([1, 2, 3], fn x ->
          Yield.yield({:visiting, x})
        end)
        |> Yield.with_handler()

      {%Comp.Suspend{value: {:visiting, 1}, resume: r1}, _e1} = Comp.run(comp)
      # Resume returns just the yield's resume value, not :ok from full iteration
      {result, _env} = r1.(:ok)
      # The result is just what the yield returned, not the full fx_each result
      assert result == :ok
    end
  end

  # ============================================================
  # Comparison note: FxFasterList vs FxList
  # ============================================================
  #
  # FxFasterList:
  # - Throw: Works correctly - short-circuits and propagates
  # - Yield: Suspends but LOSES list iteration context
  #   - Resume only continues the single element's computation
  #   - Remaining list elements are lost
  #
  # FxList:
  # - Throw: Works correctly - short-circuits and propagates
  # - Yield: Works correctly - resume continues from exact point
  #   - Full list iteration context is preserved in continuation
  #   - Can resume through all elements
  #
  # For computations that use Yield/Suspend, use FxList.
  # For computations that only use Throw (or no control effects),
  # both work, but FxFasterList may have better performance for large lists.
end
