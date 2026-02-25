defmodule Skuld.Effects.BrookTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

      # Order IS preserved with concurrency thanks to put_async/take_async
      assert result == [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]
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
        |> FiberPool.run!()

      assert result == {:error, :source_error}
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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

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
        |> FiberPool.run!()

      assert result == Enum.to_list(1..100)
    end
  end

  describe "Brook with I/O batching" do
    # Replicates the README.md I/O Batching example with nested fetches
    defmodule Order do
      defstruct [:id, :user_id, :total]
    end

    defmodule User do
      use Skuld.Syntax
      alias Skuld.Effects.Brook
      alias Skuld.Effects.DB

      defstruct [:id, :name, :orders]

      # Fetch a user and all their orders - composes DB.fetch with DB.fetch_all
      defcomp with_orders(user_id) do
        user <- DB.fetch(__MODULE__, user_id)
        orders <- DB.fetch_all(Order, :user_id, user_id)
        %{user | orders: orders}
      end

      # Fetch multiple users with their orders using Brook
      defcomp fetch_users_with_orders(user_ids) do
        source <- Brook.from_enum(user_ids, chunk_size: 2)
        users <- Brook.map(source, &with_orders/1, concurrency: 3)
        Brook.to_list(users)
      end
    end

    alias Skuld.Comp
    alias Skuld.Effects.DB
    alias Skuld.Fiber.FiberPool.BatchExecutor

    test "nested fetches batch across concurrent fibers" do
      test_pid = self()

      user_executor = fn ops ->
        send(test_pid, {:user_fetch, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %DB.Fetch{id: id}} ->
            {ref, %User{id: id, name: "User #{id}", orders: nil}}
          end)
        )
      end

      order_executor = fn ops ->
        send(test_pid, {:order_fetch_all, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %DB.FetchAll{filter_value: user_id}} ->
            {ref,
             [
               %Order{id: user_id * 10 + 1, user_id: user_id, total: 100},
               %Order{id: user_id * 10 + 2, user_id: user_id, total: 200}
             ]}
          end)
        )
      end

      result =
        User.fetch_users_with_orders([1, 2, 3, 4, 5])
        |> BatchExecutor.with_executor({:db_fetch, User}, user_executor)
        |> BatchExecutor.with_executor({:db_fetch_all, Order, :user_id}, order_executor)
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      # Should get all users with their orders, in order
      assert [
               %User{id: 1, name: "User 1", orders: [%Order{user_id: 1}, %Order{user_id: 1}]},
               %User{id: 2, name: "User 2", orders: [%Order{user_id: 2}, %Order{user_id: 2}]},
               %User{id: 3, name: "User 3", orders: [%Order{user_id: 3}, %Order{user_id: 3}]},
               %User{id: 4, name: "User 4", orders: [%Order{user_id: 4}, %Order{user_id: 4}]},
               %User{id: 5, name: "User 5", orders: [%Order{user_id: 5}, %Order{user_id: 5}]}
             ] = result

      # Both executors should have been called (batching happened)
      assert_received {:user_fetch, _count}
      assert_received {:order_fetch_all, _count}
    end
  end
end
