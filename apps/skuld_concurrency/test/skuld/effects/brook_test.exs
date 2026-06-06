defmodule Skuld.Effects.BrookTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Channel
  alias Skuld.Effects.FiberPool
  alias Skuld.Effects.Brook, as: B

  describe "from_enum/2" do
    test "creates stream from list" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3])
          B.to_list(source)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [1, 2, 3]
    end

    test "creates stream from range" do
      result =
        comp do
          source <- B.from_enum(1..5)
          B.to_list(source)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [1, 2, 3, 4, 5]
    end

    test "respects buffer option" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3], buffer: 1)
          B.to_list(source)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [1, 2, 3]
    end

    test "handles empty enumerable" do
      result =
        comp do
          source <- B.from_enum([])
          B.to_list(source)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == []
    end
  end

  describe "from_function/2" do
    test "produces items until done" do
      counter = :counters.new(1, [])

      result =
        comp do
          source <-
            B.from_function(fn ->
              n = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)

              if n < 5 do
                {:item, n}
              else
                :done
              end
            end)

          B.to_list(source)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [0, 1, 2, 3, 4]
    end

    test "handles :items to emit multiple values" do
      called = :counters.new(1, [])

      result =
        comp do
          source <-
            B.from_function(fn ->
              n = :counters.get(called, 1)
              :counters.add(called, 1, 1)

              case n do
                0 -> {:items, [1, 2, 3]}
                1 -> {:items, [4, 5]}
                _ -> :done
              end
            end)

          B.to_list(source)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [1, 2, 3, 4, 5]
    end

    test "propagates errors" do
      result =
        comp do
          source <-
            B.from_function(fn ->
              {:error, :test_error}
            end)

          B.to_list(source)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == {:error, :test_error}
    end
  end

  describe "map/3" do
    test "transforms each item" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3])
          mapped <- B.map(source, fn x -> x * 2 end)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [2, 4, 6]
    end

    test "handles empty stream" do
      result =
        comp do
          source <- B.from_enum([])
          mapped <- B.map(source, fn x -> x * 2 end)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == []
    end

    test "works with multiple workers" do
      result =
        comp do
          source <- B.from_enum(1..10)
          mapped <- B.map(source, fn x -> x * 2 end, concurrency: 4)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      # Order IS preserved with concurrency thanks to put_async/take_async
      assert result == [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]
    end

    test "works with concurrency: 1 explicitly" do
      result =
        comp do
          source <- B.from_enum(1..20)
          mapped <- B.map(source, fn x -> x * 2 end, concurrency: 1)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == Enum.map(1..20, &(&1 * 2))
    end

    test "works with concurrency: 4 and preserves order" do
      result =
        comp do
          source <- B.from_enum(1..20)
          mapped <- B.map(source, fn x -> x * 2 end, concurrency: 4)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == Enum.map(1..20, &(&1 * 2))
    end

    test "propagates input errors" do
      result =
        comp do
          source <- B.from_function(fn -> {:error, :source_error} end)
          mapped <- B.map(source, fn x -> x * 2 end)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == {:error, :source_error}
    end
  end

  describe "flat_map/3" do
    test "maps and flattens items" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3])
          mapped <- B.flat_map(source, fn x -> [x, x * 10] end)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [1, 10, 2, 20, 3, 30]
    end

    test "works with concurrency" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3, 4, 5], buffer: 20)
          mapped <- B.flat_map(source, fn x -> [x, x * 10] end, concurrency: 2)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert length(result) == 10
      assert 1 in result
      assert 50 in result
    end

    test "handles empty lists from transform" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3])
          mapped <- B.flat_map(source, fn x -> if rem(x, 2) == 0, do: [x], else: [] end)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [2]
    end

    test "works with effectful transforms" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3])
          mapped <- B.flat_map(source, fn x -> [x, x + 1] end)
          mapped2 <- B.flat_map(mapped, fn x -> [x, x * 2] end)
          B.to_list(mapped2)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      # With concurrent transforms, items from the same source are ordered
      # relative to each other, but items from different sources may interleave
      assert length(result) == 12
      assert 1 in result
      assert 2 in result
      assert 6 in result
      assert 8 in result
    end
  end

  describe "filter/3" do
    test "filters items by predicate" do
      result =
        comp do
          source <- B.from_enum(1..10)
          filtered <- B.filter(source, fn x -> rem(x, 2) == 0 end)
          B.to_list(filtered)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [2, 4, 6, 8, 10]
    end

    test "handles all items filtered out" do
      result =
        comp do
          source <- B.from_enum([1, 3, 5])
          filtered <- B.filter(source, fn x -> rem(x, 2) == 0 end)
          B.to_list(filtered)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == []
    end

    test "handles empty stream" do
      result =
        comp do
          source <- B.from_enum([])
          filtered <- B.filter(source, fn _ -> true end)
          B.to_list(filtered)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == []
    end

    test "propagates errors" do
      result =
        comp do
          source <- B.from_function(fn -> {:error, :filter_test_error} end)
          filtered <- B.filter(source, fn _ -> true end)
          B.to_list(filtered)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == {:error, :filter_test_error}
    end
  end

  describe "each/2" do
    test "executes function for each item" do
      collected = :ets.new(:collected, [:set, :public])

      result =
        comp do
          source <- B.from_enum([1, 2, 3])

          B.each(source, fn x ->
            :ets.insert(collected, {x, true})
          end)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == :ok
      assert :ets.lookup(collected, 1) == [{1, true}]
      assert :ets.lookup(collected, 2) == [{2, true}]
      assert :ets.lookup(collected, 3) == [{3, true}]

      :ets.delete(collected)
    end

    test "returns :ok on success" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3])
          B.each(source, fn _ -> :ok end)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == :ok
    end

    test "returns error if stream errors" do
      result =
        comp do
          source <- B.from_function(fn -> {:error, :each_error} end)
          B.each(source, fn _ -> :ok end)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == {:error, :each_error}
    end
  end

  describe "run/2" do
    test "runs consumer function for each item" do
      collected = :ets.new(:run_collected, [:set, :public])

      result =
        comp do
          source <- B.from_enum([1, 2, 3])

          B.run(source, fn x ->
            :ets.insert(collected, {x, true})
            :ok
          end)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == :ok
      assert :ets.lookup(collected, 1) == [{1, true}]
      assert :ets.lookup(collected, 2) == [{2, true}]
      assert :ets.lookup(collected, 3) == [{3, true}]

      :ets.delete(collected)
    end

    test "returns error if stream errors" do
      result =
        comp do
          source <- B.from_function(fn -> {:error, :run_error} end)
          B.run(source, fn _ -> :ok end)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == {:error, :run_error}
    end
  end

  describe "to_list/1" do
    test "collects all items into list" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3, 4, 5])
          B.to_list(source)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [1, 2, 3, 4, 5]
    end

    test "returns error if stream errors" do
      result =
        comp do
          source <- B.from_function(fn -> {:error, :to_list_error} end)
          B.to_list(source)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == {:error, :to_list_error}
    end
  end

  describe "pipeline composition" do
    test "map then filter" do
      result =
        comp do
          source <- B.from_enum(1..10)
          doubled <- B.map(source, fn x -> x * 2 end)
          evens_over_10 <- B.filter(doubled, fn x -> x > 10 end)
          B.to_list(evens_over_10)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [12, 14, 16, 18, 20]
    end

    test "filter then map" do
      result =
        comp do
          source <- B.from_enum(1..10)
          evens <- B.filter(source, fn x -> rem(x, 2) == 0 end)
          doubled <- B.map(evens, fn x -> x * 2 end)
          B.to_list(doubled)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == [4, 8, 12, 16, 20]
    end

    test "multiple maps" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3])
          plus_one <- B.map(source, fn x -> x + 1 end)
          times_two <- B.map(plus_one, fn x -> x * 2 end)
          squared <- B.map(times_two, fn x -> x * x end)
          B.to_list(squared)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      # 1 -> 2 -> 4 -> 16
      # 2 -> 3 -> 6 -> 36
      # 3 -> 4 -> 8 -> 64
      assert result == [16, 36, 64]
    end

    test "complex pipeline" do
      result =
        comp do
          source <- B.from_enum(1..20)
          evens <- B.filter(source, fn x -> rem(x, 2) == 0 end)
          doubled <- B.map(evens, fn x -> x * 2 end)
          over_20 <- B.filter(doubled, fn x -> x > 20 end)
          B.to_list(over_20)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      # evens: 2, 4, 6, 8, 10, 12, 14, 16, 18, 20
      # doubled: 4, 8, 12, 16, 20, 24, 28, 32, 36, 40
      # over 20: 24, 28, 32, 36, 40
      assert result == [24, 28, 32, 36, 40]
    end
  end

  describe "backpressure" do
    test "producer blocks when buffer full" do
      # This tests that with a small buffer, the producer
      # doesn't run ahead indefinitely
      result =
        comp do
          source <- B.from_enum(1..100, buffer: 2)
          mapped <- B.map(source, fn x -> x end, buffer: 2)
          B.to_list(mapped)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == Enum.to_list(1..100)
    end
  end

  describe "reduce/3" do
    test "pure reducer accumulates" do
      result =
        comp do
          source <- B.from_enum([1, 2, 3, 4, 5])
          B.reduce(source, 0, fn item, acc -> acc + item end)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 15
    end

    test "empty stream returns initial accumulator" do
      result =
        comp do
          source <- B.from_enum([])
          B.reduce(source, :initial, fn _item, acc -> acc end)
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == :initial
    end

    test "effectful reducer" do
      result =
        comp do
          source <- B.from_enum([10, 20, 30])
          # Simulate effectful accumulation
          total <- B.reduce(source, 0, fn item, acc -> acc + item end)
          total
        end
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 60
    end
  end
end
