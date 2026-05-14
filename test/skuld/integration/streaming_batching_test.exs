defmodule Skuld.Integration.StreamingBatchingTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Brook
  alias Skuld.Effects.Channel
  alias Skuld.Effects.FiberPool

  # ---------------------------------------------------------------
  # Data structures
  # ---------------------------------------------------------------

  defmodule User do
    defstruct [:id, :name, :email]
  end

  defmodule Order do
    defstruct [:id, :user_id, :date, :total]
  end

  defmodule OrderDetail do
    defstruct [:id, :order_id, :item, :price]
  end

  defmodule AccountSummary do
    defstruct [:user, :email, :order_count, :total_spent, :items]
  end

  # ---------------------------------------------------------------
  # Query contract
  # ---------------------------------------------------------------

  defmodule Queries do
    use Skuld.Query

    deffetch fetch_user(id :: String.t()) :: User.t() | nil
    deffetch fetch_user_orders(user_id :: String.t(), month :: String.t()) :: [Order.t()]
    deffetch fetch_order_details(order_id :: String.t()) :: [OrderDetail.t()]
  end

  # ---------------------------------------------------------------
  # Bulk API — simulates a backend with bulk endpoints
  # ---------------------------------------------------------------

  defmodule BulkAPI do
    def bulk_fetch_users(ops) when is_list(ops) do
      Map.new(ops, fn %Queries.FetchUser{id: id} = op ->
        {op, %User{id: id, name: "User #{id}", email: "user#{id}@test.com"}}
      end)
    end

    def bulk_fetch_user_orders(ops) when is_list(ops) do
      Map.new(ops, fn %Queries.FetchUserOrders{user_id: uid, month: month} = op ->
        {op,
         [
           %Order{id: "#{uid}-o1", user_id: uid, date: "#{month}-01", total: 100},
           %Order{id: "#{uid}-o2", user_id: uid, date: "#{month}-15", total: 200}
         ]}
      end)
    end

    def bulk_fetch_order_details(ops) when is_list(ops) do
      Map.new(ops, fn %Queries.FetchOrderDetails{order_id: oid} = op ->
        {op,
         [
           %OrderDetail{id: "#{oid}-d1", order_id: oid, item: "Item A", price: 50},
           %OrderDetail{id: "#{oid}-d2", order_id: oid, item: "Item B", price: 75}
         ]}
      end)
    end
  end

  # ---------------------------------------------------------------
  # Executor — bridges deffetch calls to BulkAPI, validates batching
  # ---------------------------------------------------------------

  defmodule Executor do
    @behaviour Queries

    @impl true
    def fetch_user(ops) do
      send(self(), {:batch, :fetch_user, length(ops)})

      results =
        ops
        |> Enum.map(fn {_ref, op} -> op end)
        |> BulkAPI.bulk_fetch_users()

      Map.new(ops, fn {ref, op} ->
        {ref, Map.fetch!(results, op)}
      end)
    end

    @impl true
    def fetch_user_orders(ops) do
      send(self(), {:batch, :fetch_user_orders, length(ops)})

      results =
        ops
        |> Enum.map(fn {_ref, op} -> op end)
        |> BulkAPI.bulk_fetch_user_orders()

      Map.new(ops, fn {ref, op} ->
        {ref, Map.fetch!(results, op)}
      end)
    end

    @impl true
    def fetch_order_details(ops) do
      send(self(), {:batch, :fetch_order_details, length(ops)})

      results =
        ops
        |> Enum.map(fn {_ref, op} -> op end)
        |> BulkAPI.bulk_fetch_order_details()

      Map.new(ops, fn {ref, op} ->
        {ref, Map.fetch!(results, op)}
      end)
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp build_summary(%User{} = user, orders, all_details) do
    details = List.flatten(all_details)
    total_spent = Enum.reduce(details, 0, &(&1.price + &2))
    items = Enum.map(details, & &1.item) |> Enum.uniq()

    %AccountSummary{
      user: user.name,
      email: user.email,
      order_count: length(orders),
      total_spent: total_spent,
      items: items
    }
  end

  # ---------------------------------------------------------------
  # Query block — builds a monthly account summary for one user
  # ---------------------------------------------------------------

  defquery build_user_summary(user_id, month) do
    user <- Queries.fetch_user(user_id)
    orders <- Queries.fetch_user_orders(user_id, month)
    order_ids = Enum.map(orders, & &1.id)

    details_list <-
      Comp.sequence(Enum.map(order_ids, fn oid -> Queries.fetch_order_details(oid) end))

    Comp.pure(build_summary(user, orders, details_list))
  end

  # ---------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------

  describe "streaming with brook and query batching" do
    test "maps user IDs through a query block, batches deffetch calls automatically" do
      user_ids = ["u1", "u2", "u3", "u4", "u5", "u6", "u7", "u8", "u9", "u10"]
      month = "2026-01"

      result =
        comp do
          source <- Brook.from_enum(user_ids, chunk_size: 5, buffer: 5)
          summaries <- Brook.map(source, fn user_id -> build_user_summary(user_id, month) end, concurrency: 4)
          Brook.to_list(summaries)
        end
        |> Skuld.Query.with_executor(Queries, Executor)
        |> Channel.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert length(result) == 10

      Enum.with_index(user_ids, 1)
      |> Enum.each(fn {id, idx} ->
        summary = Enum.at(result, idx - 1)
        assert %AccountSummary{} = summary
        assert summary.user == "User #{id}"
        assert summary.email == "user#{id}@test.com"
        assert summary.order_count == 2
        assert summary.total_spent == 250
        assert summary.items == ["Item A", "Item B"]
      end)

      # Batching: Brook.map concurrency: 4 runs up to 4 transforms concurrently.
      # Each transform runs a query block that spawns fetch_user and
      # fetch_user_orders in the same batch via fiber_all. The FiberPool
      # scheduler groups suspensions by batch key across fibers.
      all_messages =
        Enum.map(1..50, fn _ ->
          receive do
            msg -> msg
          after
            0 -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&match?({:batch, _, _}, &1))

      user_batches = Enum.filter(all_messages, &match?({:batch, :fetch_user, _}, &1))
      orders_batches = Enum.filter(all_messages, &match?({:batch, :fetch_user_orders, _}, &1))
      details_batches = Enum.filter(all_messages, &match?({:batch, :fetch_order_details, _}, &1))

      assert Enum.map(user_batches, &elem(&1, 2)) == [2, 2, 2, 2, 2]
      assert Enum.map(orders_batches, &elem(&1, 2)) == [2, 2, 2, 2, 2]

      # 10 users × 2 orders = 20 detail fetches, batched
      assert Enum.sum(Enum.map(details_batches, &elem(&1, 2))) == 20
    end
  end
end
