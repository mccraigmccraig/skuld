defmodule Skuld.Query.CacheTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.FiberPool
  alias Skuld.Query.Cache, as: QueryCache

  # ---------------------------------------------------------------
  # Test contract and executor
  # ---------------------------------------------------------------

  defmodule User do
    defstruct [:id, :name]
  end

  defmodule Order do
    defstruct [:id, :total]
  end

  defmodule TestQueries do
    use Skuld.Query.Contract

    deffetch(get_user(id :: String.t()) :: User.t() | nil)
    deffetch(list_users(org_id :: String.t()) :: [User.t()])
  end

  defmodule CacheOptQueries do
    use Skuld.Query.Contract

    deffetch(get_user(id :: String.t()) :: User.t() | nil)
    deffetch(get_random(seed :: String.t()) :: term(), cache: false)
  end

  defmodule OrderQueries do
    use Skuld.Query.Contract

    deffetch(get_order(id :: String.t()) :: Order.t() | nil)
  end

  defmodule CountingExecutor do
    @moduledoc """
    An executor that counts invocations via message passing.
    Each batch call sends {:executor_called, query_name, ops_count} to the test process.
    """
    @behaviour TestQueries.Executor

    @impl true
    def get_user(ops) do
      test_pid = find_test_pid()
      send(test_pid, {:executor_called, :get_user, length(ops)})

      Comp.pure(
        Map.new(ops, fn {ref, %TestQueries.GetUser{id: id}} ->
          {ref, %User{id: id, name: "User #{id}"}}
        end)
      )
    end

    @impl true
    def list_users(ops) do
      test_pid = find_test_pid()
      send(test_pid, {:executor_called, :list_users, length(ops)})

      Comp.pure(
        Map.new(ops, fn {ref, %TestQueries.ListUsers{org_id: org_id}} ->
          {ref, [%User{id: "#{org_id}-1", name: "User A"}]}
        end)
      )
    end

    defp find_test_pid do
      Process.get(:test_pid) || raise "test_pid not set in process dictionary"
    end
  end

  defmodule CacheOptExecutor do
    @behaviour CacheOptQueries.Executor

    @impl true
    def get_user(ops) do
      test_pid = Process.get(:test_pid) || raise "test_pid not set"
      send(test_pid, {:executor_called, :cache_opt_get_user, length(ops)})

      Comp.pure(
        Map.new(ops, fn {ref, %CacheOptQueries.GetUser{id: id}} ->
          {ref, %User{id: id, name: "User #{id}"}}
        end)
      )
    end

    @impl true
    def get_random(ops) do
      test_pid = Process.get(:test_pid) || raise "test_pid not set"
      send(test_pid, {:executor_called, :get_random, length(ops)})

      Comp.pure(
        Map.new(ops, fn {ref, %CacheOptQueries.GetRandom{seed: seed}} ->
          {ref, "random-#{seed}-#{System.unique_integer()}"}
        end)
      )
    end
  end

  defmodule OrderExecutor do
    @behaviour OrderQueries.Executor

    @impl true
    def get_order(ops) do
      test_pid = Process.get(:test_pid) || raise "test_pid not set"
      send(test_pid, {:executor_called, :get_order, length(ops)})

      Comp.pure(
        Map.new(ops, fn {ref, %OrderQueries.GetOrder{id: id}} ->
          {ref, %Order{id: id, total: 100}}
        end)
      )
    end
  end

  defmodule FailingExecutor do
    @behaviour TestQueries.Executor

    @impl true
    def get_user(ops) do
      test_pid = Process.get(:test_pid) || raise "test_pid not set"
      send(test_pid, {:executor_called, :failing_get_user, length(ops)})
      Skuld.Effects.Throw.throw(:executor_error)
    end

    @impl true
    def list_users(_ops), do: Comp.pure(%{})
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  # We need to make the test PID available to the executor.
  # FiberPool runs in the same process, so Process dictionary works.
  defp with_test_pid(fun) do
    Process.put(:test_pid, self())

    try do
      fun.()
    after
      Process.delete(:test_pid)
    end
  end

  # ---------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------

  describe "cache miss" do
    test "first query goes to executor" do
      with_test_pid(fn ->
        result =
          comp do
            h <- FiberPool.fiber(TestQueries.get_user("1"))
            FiberPool.await!(h)
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        assert %User{id: "1", name: "User 1"} = result
        assert_received {:executor_called, :get_user, 1}
      end)
    end
  end

  describe "cache hit" do
    test "same query in a later batch round returns cached result, executor NOT called again" do
      with_test_pid(fn ->
        result =
          comp do
            # Round 1: fiber queries get_user("1") — cache miss
            h1 <- FiberPool.fiber(TestQueries.get_user("1"))
            r1 <- FiberPool.await!(h1)

            # Round 2: another fiber queries get_user("1") — cache hit
            h2 <- FiberPool.fiber(TestQueries.get_user("1"))
            r2 <- FiberPool.await!(h2)

            return({r1, r2})
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {r1, r2} = result
        assert %User{id: "1", name: "User 1"} = r1
        assert %User{id: "1", name: "User 1"} = r2

        # Executor should only have been called once
        assert_received {:executor_called, :get_user, 1}
        refute_received {:executor_called, :get_user, _}
      end)
    end
  end

  describe "different params miss" do
    test "get_user(A) cached, get_user(B) still goes to executor" do
      with_test_pid(fn ->
        result =
          comp do
            # Round 1: cache miss for "A"
            h1 <- FiberPool.fiber(TestQueries.get_user("A"))
            r1 <- FiberPool.await!(h1)

            # Round 2: cache miss for "B" (different params)
            h2 <- FiberPool.fiber(TestQueries.get_user("B"))
            r2 <- FiberPool.await!(h2)

            return({r1, r2})
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {r1, r2} = result
        assert %User{id: "A", name: "User A"} = r1
        assert %User{id: "B", name: "User B"} = r2

        # Two executor calls — both were misses
        assert_received {:executor_called, :get_user, 1}
        assert_received {:executor_called, :get_user, 1}
      end)
    end
  end

  describe "cross-batch caching" do
    test "fiber 1 queries in round 1, fiber 2 queries same in round 2 — cache hit" do
      with_test_pid(fn ->
        result =
          comp do
            # Start two fibers: first one runs immediately, second depends on first
            h1 <- FiberPool.fiber(TestQueries.get_user("X"))
            r1 <- FiberPool.await!(h1)

            # Now start another fiber with same query
            h2 <- FiberPool.fiber(TestQueries.get_user("X"))
            r2 <- FiberPool.await!(h2)

            return({r1, r2})
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {r1, r2} = result
        assert %User{id: "X", name: "User X"} = r1
        assert %User{id: "X", name: "User X"} = r2

        # Only one executor call
        assert_received {:executor_called, :get_user, 1}
        refute_received {:executor_called, :get_user, _}
      end)
    end
  end

  describe "cache scope cleanup" do
    test "after computation completes, cache does not leak to outer scope" do
      with_test_pid(fn ->
        # Run a computation that populates the cache
        inner_result =
          comp do
            h <- FiberPool.fiber(TestQueries.get_user("1"))
            FiberPool.await!(h)
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        assert %User{id: "1"} = inner_result
        assert_received {:executor_called, :get_user, 1}

        # Run another computation — the cache should be empty
        outer_result =
          comp do
            h <- FiberPool.fiber(TestQueries.get_user("1"))
            FiberPool.await!(h)
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        assert %User{id: "1"} = outer_result

        # Executor must be called again — cache was cleaned up
        assert_received {:executor_called, :get_user, 1}
      end)
    end
  end

  describe "within-batch dedup" do
    test "two fibers requesting same query in same round — executor receives one op" do
      with_test_pid(fn ->
        result =
          comp do
            # Both fibers start in the same round — same query
            h1 <- FiberPool.fiber(TestQueries.get_user("X"))
            h2 <- FiberPool.fiber(TestQueries.get_user("X"))
            FiberPool.await_all!([h1, h2])
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        # Both fibers get the result
        assert [%User{id: "X", name: "User X"}, %User{id: "X", name: "User X"}] = result

        # Executor called once with 1 op (deduped from 2)
        assert_received {:executor_called, :get_user, 1}
        refute_received {:executor_called, :get_user, _}
      end)
    end

    test "dedup with different ops in same round" do
      with_test_pid(fn ->
        result =
          comp do
            h1 <- FiberPool.fiber(TestQueries.get_user("X"))
            h2 <- FiberPool.fiber(TestQueries.get_user("X"))
            h3 <- FiberPool.fiber(TestQueries.get_user("Y"))
            FiberPool.await_all!([h1, h2, h3])
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        # All three fibers get correct results
        assert [
                 %User{id: "X", name: "User X"},
                 %User{id: "X", name: "User X"},
                 %User{id: "Y", name: "User Y"}
               ] = result

        # Executor called once with 2 ops (X and Y — deduped from 3)
        assert_received {:executor_called, :get_user, 2}
        refute_received {:executor_called, :get_user, _}
      end)
    end

    test "dedup populates cache — subsequent rounds hit cache" do
      with_test_pid(fn ->
        result =
          comp do
            # Round 1: two fibers both request get_user("X") — deduped
            h1 <- FiberPool.fiber(TestQueries.get_user("X"))
            h2 <- FiberPool.fiber(TestQueries.get_user("X"))
            [r1, r2] <- FiberPool.await_all!([h1, h2])

            # Round 2: another fiber requests get_user("X") — cache hit
            h3 <- FiberPool.fiber(TestQueries.get_user("X"))
            r3 <- FiberPool.await!(h3)

            return({r1, r2, r3})
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {r1, r2, r3} = result
        assert %User{id: "X"} = r1
        assert %User{id: "X"} = r2
        assert %User{id: "X"} = r3

        # Executor called only once (round 1 deduped, round 2 cached)
        assert_received {:executor_called, :get_user, 1}
        refute_received {:executor_called, :get_user, _}
      end)
    end

    test "three or more duplicates in same round" do
      with_test_pid(fn ->
        result =
          comp do
            h1 <- FiberPool.fiber(TestQueries.get_user("Z"))
            h2 <- FiberPool.fiber(TestQueries.get_user("Z"))
            h3 <- FiberPool.fiber(TestQueries.get_user("Z"))
            h4 <- FiberPool.fiber(TestQueries.get_user("Z"))
            FiberPool.await_all!([h1, h2, h3, h4])
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        assert [
                 %User{id: "Z", name: "User Z"},
                 %User{id: "Z", name: "User Z"},
                 %User{id: "Z", name: "User Z"},
                 %User{id: "Z", name: "User Z"}
               ] = result

        # Executor called once with 1 op
        assert_received {:executor_called, :get_user, 1}
        refute_received {:executor_called, :get_user, _}
      end)
    end
  end

  describe "with_executor shorthand" do
    test "single-contract API works identically to with_executors" do
      with_test_pid(fn ->
        result =
          comp do
            h1 <- FiberPool.fiber(TestQueries.get_user("1"))
            r1 <- FiberPool.await!(h1)

            h2 <- FiberPool.fiber(TestQueries.get_user("1"))
            r2 <- FiberPool.await!(h2)

            return({r1, r2})
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {r1, r2} = result
        assert %User{id: "1"} = r1
        assert %User{id: "1"} = r2

        # Cache hit on second query
        assert_received {:executor_called, :get_user, 1}
        refute_received {:executor_called, :get_user, _}
      end)
    end
  end

  describe "cache: false opt-out" do
    test "uncacheable query always hits executor" do
      with_test_pid(fn ->
        result =
          comp do
            h1 <- FiberPool.fiber(CacheOptQueries.get_random("seed1"))
            r1 <- FiberPool.await!(h1)

            # Same query again — should NOT be cached
            h2 <- FiberPool.fiber(CacheOptQueries.get_random("seed1"))
            r2 <- FiberPool.await!(h2)

            return({r1, r2})
          end
          |> QueryCache.with_executor(CacheOptQueries, CacheOptExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {r1, r2} = result
        # Both calls hit executor — results may differ
        assert is_binary(r1)
        assert is_binary(r2)

        # Executor called twice (not cached)
        assert_received {:executor_called, :get_random, 1}
        assert_received {:executor_called, :get_random, 1}
      end)
    end

    test "cached and uncached queries coexist in same contract" do
      with_test_pid(fn ->
        result =
          comp do
            # Cacheable query
            h1 <- FiberPool.fiber(CacheOptQueries.get_user("1"))
            r1 <- FiberPool.await!(h1)

            # Same cacheable query — cache hit
            h2 <- FiberPool.fiber(CacheOptQueries.get_user("1"))
            r2 <- FiberPool.await!(h2)

            # Uncacheable query
            h3 <- FiberPool.fiber(CacheOptQueries.get_random("s1"))
            r3 <- FiberPool.await!(h3)

            # Same uncacheable query — not cached
            h4 <- FiberPool.fiber(CacheOptQueries.get_random("s1"))
            r4 <- FiberPool.await!(h4)

            return({r1, r2, r3, r4})
          end
          |> QueryCache.with_executor(CacheOptQueries, CacheOptExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {r1, r2, r3, r4} = result
        # Cacheable: same result
        assert %User{id: "1"} = r1
        assert %User{id: "1"} = r2
        # Uncacheable: both are strings
        assert is_binary(r3)
        assert is_binary(r4)

        # get_user called once (cached), get_random called twice (not cached)
        assert_received {:executor_called, :cache_opt_get_user, 1}
        refute_received {:executor_called, :cache_opt_get_user, _}
        assert_received {:executor_called, :get_random, 1}
        assert_received {:executor_called, :get_random, 1}
      end)
    end
  end

  describe "executor failure not cached" do
    test "executor failure does not populate cache — next request retries" do
      with_test_pid(fn ->
        # First call: executor fails
        assert_raise RuntimeError, ~r/Fiber failed/, fn ->
          comp do
            h <- FiberPool.fiber(TestQueries.get_user("1"))
            FiberPool.await!(h)
          end
          |> QueryCache.with_executor(TestQueries, FailingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()
        end

        assert_received {:executor_called, :failing_get_user, 1}

        # Second call with working executor — should NOT hit cache
        # (failure wasn't cached), should go to executor
        result =
          comp do
            h <- FiberPool.fiber(TestQueries.get_user("1"))
            FiberPool.await!(h)
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        assert %User{id: "1"} = result
        assert_received {:executor_called, :get_user, 1}
      end)
    end
  end

  describe "multi-contract shared cache" do
    test "two contracts cached independently via with_executors" do
      with_test_pid(fn ->
        result =
          comp do
            # Query from both contracts
            h1 <- FiberPool.fiber(TestQueries.get_user("1"))
            h2 <- FiberPool.fiber(OrderQueries.get_order("o1"))
            [r1, r2] <- FiberPool.await_all!([h1, h2])

            # Same queries again — both should be cache hits
            h3 <- FiberPool.fiber(TestQueries.get_user("1"))
            h4 <- FiberPool.fiber(OrderQueries.get_order("o1"))
            [r3, r4] <- FiberPool.await_all!([h3, h4])

            return({r1, r2, r3, r4})
          end
          |> QueryCache.with_executors([
            {TestQueries, CountingExecutor},
            {OrderQueries, OrderExecutor}
          ])
          |> FiberPool.with_handler()
          |> Comp.run!()

        {r1, r2, r3, r4} = result
        assert %User{id: "1"} = r1
        assert %Order{id: "o1", total: 100} = r2
        assert %User{id: "1"} = r3
        assert %Order{id: "o1", total: 100} = r4

        # Each executor called once (second calls were cache hits)
        assert_received {:executor_called, :get_user, 1}
        refute_received {:executor_called, :get_user, _}
        assert_received {:executor_called, :get_order, 1}
        refute_received {:executor_called, :get_order, _}
      end)
    end

    test "nested with_executors calls share the outer cache scope" do
      with_test_pid(fn ->
        # Inner with_executors (Users) wraps the comp, outer (Orders) wraps that.
        # Both should share a single cache — the outer scope's.
        result =
          comp do
            # Round 1: query from both contracts — cache misses
            h1 <- FiberPool.fiber(TestQueries.get_user("1"))
            h2 <- FiberPool.fiber(OrderQueries.get_order("o1"))
            [r1, r2] <- FiberPool.await_all!([h1, h2])

            # Round 2: same queries again — both should be cache hits
            h3 <- FiberPool.fiber(TestQueries.get_user("1"))
            h4 <- FiberPool.fiber(OrderQueries.get_order("o1"))
            [r3, r4] <- FiberPool.await_all!([h3, h4])

            return({r1, r2, r3, r4})
          end
          |> QueryCache.with_executor(TestQueries, CountingExecutor)
          |> QueryCache.with_executor(OrderQueries, OrderExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {r1, r2, r3, r4} = result
        assert %User{id: "1"} = r1
        assert %Order{id: "o1", total: 100} = r2
        assert %User{id: "1"} = r3
        assert %Order{id: "o1", total: 100} = r4

        # Each executor called once — second calls were cache hits from shared cache
        assert_received {:executor_called, :get_user, 1}
        refute_received {:executor_called, :get_user, _}
        assert_received {:executor_called, :get_order, 1}
        refute_received {:executor_called, :get_order, _}
      end)
    end

    test "no collision between contracts with same query name and params" do
      with_test_pid(fn ->
        # Both TestQueries and CacheOptQueries have get_user
        result =
          comp do
            h1 <- FiberPool.fiber(TestQueries.get_user("1"))
            h2 <- FiberPool.fiber(CacheOptQueries.get_user("1"))
            FiberPool.await_all!([h1, h2])
          end
          |> QueryCache.with_executors([
            {TestQueries, CountingExecutor},
            {CacheOptQueries, CacheOptExecutor}
          ])
          |> FiberPool.with_handler()
          |> Comp.run!()

        assert [%User{id: "1"}, %User{id: "1"}] = result

        # Both executors called — different batch keys, no sharing
        assert_received {:executor_called, :get_user, 1}
        assert_received {:executor_called, :cache_opt_get_user, 1}
      end)
    end
  end
end
