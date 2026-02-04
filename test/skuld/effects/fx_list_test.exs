defmodule Skuld.Effects.FxListTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.FxList
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield

  describe "fx_map" do
    test "maps effectful function over empty list" do
      comp =
        FxList.fx_map([], fn x -> Comp.pure(x * 2) end)

      assert Comp.run!(comp) == []
    end

    test "maps effectful function over list" do
      comp =
        FxList.fx_map([1, 2, 3], fn x -> Comp.pure(x * 2) end)

      assert Comp.run!(comp) == [2, 4, 6]
    end

    test "maps with stateful effects" do
      comp =
        FxList.fx_map([1, 2, 3], fn x ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              Comp.pure({x, count})
            end)
          end)
        end)
        |> State.with_handler(0)

      assert Comp.run!(comp) == [{1, 0}, {2, 1}, {3, 2}]
    end

    test "works with range" do
      comp =
        FxList.fx_map(1..3, fn x -> Comp.pure(x * 2) end)

      assert Comp.run!(comp) == [2, 4, 6]
    end
  end

  describe "fx_reduce" do
    test "reduces empty list to initial value" do
      comp =
        FxList.fx_reduce([], 0, fn x, acc -> Comp.pure(acc + x) end)

      assert Comp.run!(comp) == 0
    end

    test "reduces list with effectful function" do
      comp =
        FxList.fx_reduce([1, 2, 3, 4], 0, fn x, acc -> Comp.pure(acc + x) end)

      assert Comp.run!(comp) == 10
    end

    test "reduces with stateful effects" do
      comp =
        FxList.fx_reduce([1, 2, 3], [], fn x, acc ->
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
          FxList.fx_each([1, 2, 3], fn x ->
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
        FxList.fx_each([1, 2, 3], fn _ -> Comp.pure(:ignored) end)

      assert Comp.run!(comp) == :ok
    end

    test "works with range" do
      comp =
        Comp.bind(
          FxList.fx_each(1..5, fn _ ->
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
        FxList.fx_filter([], fn x -> Comp.pure(x > 0) end)

      assert Comp.run!(comp) == []
    end

    test "filters list with pure predicate" do
      comp =
        FxList.fx_filter([1, 2, 3, 4, 5], fn x -> Comp.pure(rem(x, 2) == 0) end)

      assert Comp.run!(comp) == [2, 4]
    end

    test "filters with stateful predicate" do
      # Keep only elements where state counter is even
      comp =
        FxList.fx_filter([1, 2, 3, 4, 5], fn _x ->
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
        FxList.fx_map([1, 2, 3, 4, 5], fn x ->
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
        FxList.fx_map([1, 2, 3, 4, 5], fn x ->
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
        FxList.fx_map([1, 2, 3], fn x -> Comp.pure(x * 2) end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert result == [2, 4, 6]
    end

    test "try_catch wraps result" do
      comp =
        Throw.try_catch(
          FxList.fx_map([1, 2, 3], fn x ->
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

    test "try_catch returns ok on success" do
      comp =
        Throw.try_catch(FxList.fx_map([1, 2, 3], fn x -> Comp.pure(x * 2) end))
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert {:ok, [2, 4, 6]} = result
    end
  end

  describe "fx_reduce with Throw" do
    test "throw in reducer short-circuits" do
      comp =
        FxList.fx_reduce([1, 2, 3, 4, 5], 0, fn x, acc ->
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
          FxList.fx_each([1, 2, 3, 4, 5], fn x ->
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
        FxList.fx_filter([1, 2, 3, 4, 5], fn x ->
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
  # ============================================================

  describe "fx_map with Yield" do
    test "yield in middle of list can be resumed" do
      comp =
        FxList.fx_map([1, 2, 3, 4, 5], fn x ->
          Comp.bind(Yield.yield({:processing, x}), fn _ ->
            Comp.pure(x * 2)
          end)
        end)
        |> Yield.with_handler()

      # First run should yield with first element
      {%Comp.ExternalSuspend{value: {:processing, 1}, resume: r1}, _e1} = Comp.run(comp)

      # Resume and get next yield
      {%Comp.ExternalSuspend{value: {:processing, 2}, resume: r2}, _e2} = r1.(:resumed_1)
      {%Comp.ExternalSuspend{value: {:processing, 3}, resume: r3}, _e3} = r2.(:resumed_2)
      {%Comp.ExternalSuspend{value: {:processing, 4}, resume: r4}, _e4} = r3.(:resumed_3)
      {%Comp.ExternalSuspend{value: {:processing, 5}, resume: r5}, _e5} = r4.(:resumed_4)

      # Final resume returns completed result
      {final, _env} = r5.(:resumed_5)
      assert final == [2, 4, 6, 8, 10]
    end

    test "yield preserves state across resumes" do
      comp =
        FxList.fx_map([1, 2, 3], fn x ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              Comp.bind(Yield.yield({:at_count, count}), fn _ ->
                Comp.pure({x, count})
              end)
            end)
          end)
        end)
        |> State.with_handler(0)
        |> Yield.with_handler()

      # Process through all yields
      {%Comp.ExternalSuspend{value: {:at_count, 0}, resume: r1}, _e1} = Comp.run(comp)
      {%Comp.ExternalSuspend{value: {:at_count, 1}, resume: r2}, _e2} = r1.(:ok)
      {%Comp.ExternalSuspend{value: {:at_count, 2}, resume: r3}, _e3} = r2.(:ok)
      {result, _env} = r3.(:ok)

      assert result == [{1, 0}, {2, 1}, {3, 2}]
    end
  end

  describe "fx_reduce with Yield" do
    test "yield in reducer can be resumed" do
      comp =
        FxList.fx_reduce([1, 2, 3], 0, fn x, acc ->
          Comp.bind(Yield.yield({:reducing, x, acc}), fn _ ->
            Comp.pure(acc + x)
          end)
        end)
        |> Yield.with_handler()

      {%Comp.ExternalSuspend{value: {:reducing, 1, 0}, resume: r1}, _e1} = Comp.run(comp)
      {%Comp.ExternalSuspend{value: {:reducing, 2, 1}, resume: r2}, _e2} = r1.(:ok)
      {%Comp.ExternalSuspend{value: {:reducing, 3, 3}, resume: r3}, _e3} = r2.(:ok)
      {result, _env} = r3.(:ok)
      assert result == 6
    end
  end

  describe "fx_each with Yield" do
    test "yield in each can be resumed" do
      comp =
        FxList.fx_each([1, 2, 3], fn x ->
          Yield.yield({:visiting, x})
        end)
        |> Yield.with_handler()

      {%Comp.ExternalSuspend{value: {:visiting, 1}, resume: r1}, _e1} = Comp.run(comp)
      {%Comp.ExternalSuspend{value: {:visiting, 2}, resume: r2}, _e2} = r1.(:ok)
      {%Comp.ExternalSuspend{value: {:visiting, 3}, resume: r3}, _e3} = r2.(:ok)
      {result, _env} = r3.(:ok)
      assert result == :ok
    end
  end

  describe "fx_filter with Yield" do
    test "yield in predicate can be resumed" do
      comp =
        FxList.fx_filter([1, 2, 3, 4], fn x ->
          Comp.bind(Yield.yield({:checking, x}), fn _ ->
            Comp.pure(rem(x, 2) == 0)
          end)
        end)
        |> Yield.with_handler()

      {%Comp.ExternalSuspend{value: {:checking, 1}, resume: r1}, _e1} = Comp.run(comp)
      {%Comp.ExternalSuspend{value: {:checking, 2}, resume: r2}, _e2} = r1.(:ok)
      {%Comp.ExternalSuspend{value: {:checking, 3}, resume: r3}, _e3} = r2.(:ok)
      {%Comp.ExternalSuspend{value: {:checking, 4}, resume: r4}, _e4} = r3.(:ok)
      {result, _env} = r4.(:ok)
      assert result == [2, 4]
    end
  end

  # ============================================================
  # Combined Control Effects
  # ============================================================

  describe "combined Throw and Yield" do
    test "throw after yield short-circuits" do
      comp =
        FxList.fx_map([1, 2, 3], fn x ->
          Comp.bind(Yield.yield({:before, x}), fn _ ->
            if x == 2 do
              Throw.throw(:error_at_2)
            else
              Comp.pure(x * 2)
            end
          end)
        end)
        |> Throw.with_handler()
        |> Yield.with_handler()

      # First yield
      {%Comp.ExternalSuspend{value: {:before, 1}, resume: r1}, _e1} = Comp.run(comp)
      # Resume, get second yield
      {%Comp.ExternalSuspend{value: {:before, 2}, resume: r2}, _e2} = r1.(:ok)
      # Resume, throw happens - should be wrapped in Throw struct
      {result, _env} = r2.(:ok)
      assert %Comp.Throw{error: :error_at_2} = result
    end

    test "yield after throw recovery continues" do
      comp =
        FxList.fx_map([1, 2, 3], fn x ->
          inner =
            Throw.catch_error(
              if x == 2 do
                Throw.throw(:error_at_2)
              else
                Comp.pure(x * 2)
              end,
              fn _err -> Comp.pure(:recovered) end
            )

          Comp.bind(inner, fn result ->
            Comp.bind(Yield.yield({:after, x, result}), fn _ ->
              Comp.pure(result)
            end)
          end)
        end)
        |> Throw.with_handler()
        |> Yield.with_handler()

      # First yield
      {%Comp.ExternalSuspend{value: {:after, 1, 2}, resume: r1}, _e1} = Comp.run(comp)
      # Second yield (with recovered value)
      {%Comp.ExternalSuspend{value: {:after, 2, :recovered}, resume: r2}, _e2} = r1.(:ok)
      # Third yield
      {%Comp.ExternalSuspend{value: {:after, 3, 6}, resume: r3}, _e3} = r2.(:ok)
      # Final result
      {result, _env} = r3.(:ok)
      assert result == [2, :recovered, 6]
    end
  end

  # ============================================================
  # Yield.collect and Yield.feed helpers
  # ============================================================

  describe "with Yield.collect" do
    test "collects all yields from fx_map" do
      comp =
        FxList.fx_map([1, 2, 3], fn x ->
          Comp.bind(Yield.yield(x), fn _ ->
            Comp.pure(x * 2)
          end)
        end)
        |> Yield.with_handler()

      {:done, result, yields, _env} = Yield.collect(comp)
      assert result == [2, 4, 6]
      assert yields == [1, 2, 3]
    end
  end

  describe "with Yield.feed" do
    test "feeds inputs to yields in fx_map" do
      comp =
        FxList.fx_map([1, 2, 3], fn x ->
          Comp.bind(Yield.yield({:want_multiplier, x}), fn mult ->
            Comp.pure(x * mult)
          end)
        end)
        |> Yield.with_handler()

      {:done, result, yields, _env} = Yield.feed(comp, [10, 20, 30])
      assert result == [10, 40, 90]
      assert yields == [{:want_multiplier, 1}, {:want_multiplier, 2}, {:want_multiplier, 3}]
    end

    test "suspends when inputs exhausted" do
      comp =
        FxList.fx_map([1, 2, 3], fn x ->
          Comp.bind(Yield.yield(x), fn _ ->
            Comp.pure(x * 2)
          end)
        end)
        |> Yield.with_handler()

      # Only provide one input
      {:suspended, 2, _resume, [1], _env} = Yield.feed(comp, [:a])
    end
  end
end
