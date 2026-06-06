defmodule Skuld.Integration.BrookBatchingTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Brook
  alias Skuld.Effects.Channel
  alias Skuld.Effects.FiberPool

  # Demonstrates automatic batching of nested I/O using QueryContract.
  # Fetching users and their orders — both operations get batched across fibers.

  defmodule Order do
    defstruct [:id, :user_id, :total]
  end

  defmodule Queries do
    use Skuld.QueryContract

    deffetch fetch_user(id :: pos_integer()) :: map() | nil
    deffetch fetch_orders(user_id :: pos_integer()) :: [map()]
  end

  defmodule User do
    defstruct [:id, :name, :orders]
  end

  defmodule UserFetch do
    use Skuld.Syntax

    alias Skuld.Integration.BrookBatchingTest.Queries
    alias Skuld.Effects.Brook

    defcomp with_orders(user_id) do
      user <- Queries.fetch_user(user_id)
      orders <- Queries.fetch_orders(user_id)
      %{user | orders: orders}
    end

    defcomp fetch_users_with_orders(user_ids) do
      source <- Brook.from_enum(user_ids, chunk_size: 2)
      users <- Brook.map(source, &with_orders/1, concurrency: 3)
      Brook.to_list(users)
    end
  end

  defmodule BrookBatchExecutor do
    @behaviour Skuld.Integration.BrookBatchingTest.Queries

    @impl true
    def fetch_user(ops) do
      send(Process.get(:test_pid), {:user_fetch, length(ops)})

      Map.new(ops, fn {ref, %Skuld.Integration.BrookBatchingTest.Queries.FetchUser{id: id}} ->
        {ref, %Skuld.Integration.BrookBatchingTest.User{id: id, name: "User #{id}", orders: nil}}
      end)
    end

    @impl true
    def fetch_orders(ops) do
      send(Process.get(:test_pid), {:order_fetch, length(ops)})

      Map.new(ops, fn {ref,
                       %Skuld.Integration.BrookBatchingTest.Queries.FetchOrders{user_id: user_id}} ->
        {ref,
         [
           %Skuld.Integration.BrookBatchingTest.Order{
             id: user_id * 10 + 1,
             user_id: user_id,
             total: 100
           },
           %Skuld.Integration.BrookBatchingTest.Order{
             id: user_id * 10 + 2,
             user_id: user_id,
             total: 200
           }
         ]}
      end)
    end
  end

  test "nested fetches batch across concurrent fibers" do
    Process.put(:test_pid, self())

    result =
      UserFetch.fetch_users_with_orders([1, 2, 3, 4, 5])
      |> Skuld.QueryContract.with_executor(Queries, BrookBatchExecutor)
      |> Channel.with_handler()
      |> FiberPool.with_handler()
      |> Comp.run!()

    assert [
             %User{id: 1, name: "User 1", orders: [%Order{user_id: 1}, %Order{user_id: 1}]},
             %User{id: 2, name: "User 2", orders: [%Order{user_id: 2}, %Order{user_id: 2}]},
             %User{id: 3, name: "User 3", orders: [%Order{user_id: 3}, %Order{user_id: 3}]},
             %User{id: 4, name: "User 4", orders: [%Order{user_id: 4}, %Order{user_id: 4}]},
             %User{id: 5, name: "User 5", orders: [%Order{user_id: 5}, %Order{user_id: 5}]}
           ] = result

    assert_received {:user_fetch, _count}
    assert_received {:order_fetch, _count}
  end
end
