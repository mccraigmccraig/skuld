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

  defmodule TestQueries do
    use Skuld.Query.Contract

    defquery(get_user(id :: String.t()) :: User.t() | nil)
    defquery(list_users(org_id :: String.t()) :: [User.t()])
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
          |> FiberPool.run!()

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
          |> FiberPool.run!()

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
          |> FiberPool.run!()

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
          |> FiberPool.run!()

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
          |> FiberPool.run!()

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
          |> FiberPool.run!()

        assert %User{id: "1"} = outer_result

        # Executor must be called again — cache was cleaned up
        assert_received {:executor_called, :get_user, 1}
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
          |> FiberPool.run!()

        {r1, r2} = result
        assert %User{id: "1"} = r1
        assert %User{id: "1"} = r2

        # Cache hit on second query
        assert_received {:executor_called, :get_user, 1}
        refute_received {:executor_called, :get_user, _}
      end)
    end
  end
end
