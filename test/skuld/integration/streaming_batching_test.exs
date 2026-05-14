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
    def bulk_fetch_users(ids) when is_list(ids) do
      Map.new(ids, fn id ->
        {id, %User{id: id, name: "User #{id}", email: "user#{id}@test.com"}}
      end)
    end

    def bulk_fetch_user_orders(queries) when is_list(queries) do
      Map.new(queries, fn {user_id, month} ->
        key = {user_id, month}

        {key,
         [
           %Order{id: "#{user_id}-o1", user_id: user_id, date: "#{month}-01", total: 100},
           %Order{id: "#{user_id}-o2", user_id: user_id, date: "#{month}-15", total: 200}
         ]}
      end)
    end

    def bulk_fetch_order_details(order_ids) when is_list(order_ids) do
      Map.new(order_ids, fn order_id ->
        {order_id,
         [
           %OrderDetail{id: "#{order_id}-d1", order_id: order_id, item: "Item A", price: 50},
           %OrderDetail{id: "#{order_id}-d2", order_id: order_id, item: "Item B", price: 75}
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

      ids = Enum.map(ops, fn {_ref, %Queries.FetchUser{id: id}} -> id end)
      results = BulkAPI.bulk_fetch_users(ids)

      Map.new(ops, fn {ref, %Queries.FetchUser{id: id}} ->
        {ref, Map.fetch!(results, id)}
      end)
    end

    @impl true
    def fetch_user_orders(ops) do
      send(self(), {:batch, :fetch_user_orders, length(ops)})

      queries =
        Enum.map(ops, fn {_ref, %Queries.FetchUserOrders{user_id: uid, month: m}} ->
          {uid, m}
        end)

      results = BulkAPI.bulk_fetch_user_orders(queries)

      Map.new(ops, fn {ref, %Queries.FetchUserOrders{user_id: uid, month: m}} ->
        {ref, Map.fetch!(results, {uid, m})}
      end)
    end

    @impl true
    def fetch_order_details(ops) do
      send(self(), {:batch, :fetch_order_details, length(ops)})

      order_ids =
        Enum.map(ops, fn {_ref, %Queries.FetchOrderDetails{order_id: oid}} -> oid end)

      results = BulkAPI.bulk_fetch_order_details(order_ids)

      Map.new(ops, fn {ref, %Queries.FetchOrderDetails{order_id: oid}} ->
        {ref, Map.fetch!(results, oid)}
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
          summaries <- Brook.map(source, fn user_id -> build_user_summary(user_id, month) end)
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

      # Batching: Brook processes 2 transforms concurrently by default.
      # Each transform runs a query block with 1 fetch_user + 1 fetch_user_orders
      # + 2 fetch_order_details (2 orders per user). The FiberPool scheduler
      # groups these across fibers by batch key.
      assert_received {:batch, :fetch_user, 2}
      assert_received {:batch, :fetch_user, 2}
      assert_received {:batch, :fetch_user, 2}
      assert_received {:batch, :fetch_user, 2}
      assert_received {:batch, :fetch_user, 2}

      assert_received {:batch, :fetch_user_orders, 2}
      assert_received {:batch, :fetch_user_orders, 2}
      assert_received {:batch, :fetch_user_orders, 2}
      assert_received {:batch, :fetch_user_orders, 2}
      assert_received {:batch, :fetch_user_orders, 2}

      # 10 users × 2 orders = 20 detail fetches, batched in pairs
      Enum.each(1..10, fn _ ->
        assert_received {:batch, :fetch_order_details, 2}
      end)
    end
  end
end
