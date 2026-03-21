defmodule Skuld.Query.QueryBlockTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  import ExUnit.CaptureIO

  alias Skuld.Comp
  alias Skuld.Effects.FiberPool
  alias Skuld.Effects.State

  # ---------------------------------------------------------------
  # Test contract for batching verification
  # ---------------------------------------------------------------

  defmodule User do
    defstruct [:id, :name]
  end

  defmodule TestQueries do
    use Skuld.Query.Contract

    deffetch(get_user(id :: String.t()) :: map())
    deffetch(get_orders(user_id :: String.t()) :: [map()])
    deffetch(get_recent() :: [map()])
  end

  defmodule TestExecutor do
    @behaviour TestQueries.Executor

    @impl true
    def get_user(ops) do
      test_pid = Process.get(:test_pid)
      if test_pid, do: send(test_pid, {:get_user_batch, length(ops)})

      Comp.pure(
        Map.new(ops, fn {ref, %TestQueries.GetUser{id: id}} ->
          {ref, %{id: id, name: "User #{id}"}}
        end)
      )
    end

    @impl true
    def get_orders(ops) do
      test_pid = Process.get(:test_pid)
      if test_pid, do: send(test_pid, {:get_orders_batch, length(ops)})

      Comp.pure(
        Map.new(ops, fn {ref, %TestQueries.GetOrders{user_id: uid}} ->
          {ref, [%{id: "o1", user_id: uid}]}
        end)
      )
    end

    @impl true
    def get_recent(ops) do
      test_pid = Process.get(:test_pid)
      if test_pid, do: send(test_pid, {:get_recent_batch, length(ops)})

      Comp.pure(
        Map.new(ops, fn {ref, _op} ->
          {ref, [%{id: "recent1"}]}
        end)
      )
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp with_test_pid(fun) do
    Process.put(:test_pid, self())

    try do
      fun.()
    after
      Process.delete(:test_pid)
    end
  end

  # =====================================================================
  # Tests
  # =====================================================================

  describe "query — basic bindings" do
    test "single effectful binding" do
      result =
        query do
          a <- Comp.pure(42)
          a
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "single pure binding" do
      result =
        query do
          a = 42
          Comp.pure(a)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "final expression only (no bindings)" do
      result =
        query do
          Comp.pure(42)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "final expression auto-lifted" do
      result =
        query do
          a <- Comp.pure(42)
          a
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end
  end

  describe "query — independent bindings run concurrently" do
    test "two independent effectful bindings" do
      result =
        query do
          a <- Comp.pure(10)
          b <- Comp.pure(32)
          a + b
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "three independent effectful bindings" do
      result =
        query do
          a <- Comp.pure(10)
          b <- Comp.pure(20)
          c <- Comp.pure(12)
          a + b + c
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end
  end

  describe "query — dependency analysis" do
    test "dependent binding runs after its dependency" do
      result =
        query do
          a <- Comp.pure(21)
          b <- Comp.pure(a * 2)
          b
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "mixed independent and dependent bindings" do
      # a and b are independent (batch 1)
      # c depends on a and b (batch 2)
      result =
        query do
          a <- Comp.pure(10)
          b <- Comp.pure(32)
          c <- Comp.pure(a + b)
          c
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "diamond dependency pattern" do
      # a is independent (batch 1)
      # b depends on a, c depends on a (batch 2 — concurrent)
      # d depends on b and c (batch 3)
      result =
        query do
          a <- Comp.pure(10)
          b <- Comp.pure(a + 5)
          c <- Comp.pure(a + 17)
          d <- Comp.pure(b + c)
          d
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      # a=10, b=15, c=27, d=42
      assert result == 42
    end

    test "chain of sequential dependencies" do
      result =
        query do
          a <- Comp.pure(1)
          b <- Comp.pure(a + 1)
          c <- Comp.pure(b + 1)
          d <- Comp.pure(c + 1)
          d
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 4
    end

    test "independent pairs in separate batches" do
      # a and b are independent (batch 1)
      # c depends on a, d depends on b (batch 2 — both independent of each other)
      # e depends on c and d (batch 3)
      result =
        query do
          a <- Comp.pure(10)
          b <- Comp.pure(20)
          c <- Comp.pure(a + 2)
          d <- Comp.pure(b + 3)
          e <- Comp.pure(c + d - 3)
          e
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      # a=10, b=20, c=12, d=23, e=32
      assert result == 32
    end
  end

  describe "query — pure bindings" do
    test "pure binding with effectful dependency" do
      result =
        query do
          a <- Comp.pure(21)
          b = a * 2
          Comp.pure(b)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "independent pure and effectful bindings" do
      result =
        query do
          a <- Comp.pure(40)
          b = 2
          a + b
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end
  end

  describe "query — pattern matching" do
    test "tuple pattern in effectful binding" do
      result =
        query do
          {:ok, a} <- Comp.pure({:ok, 42})
          a
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "tuple pattern with dependency" do
      result =
        query do
          a <- Comp.pure(21)
          {:ok, b} <- Comp.pure({:ok, a * 2})
          b
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "destructured LHS variables create dependencies for later bindings" do
      # The variable `user` is extracted from a tuple pattern on the LHS.
      # A later binding referencing `user` must be in a later batch.
      result =
        query do
          {:ok, user} <- Comp.pure({:ok, %{id: "u1", name: "Alice"}})
          orders <- Comp.pure([%{id: "o1", user_id: user.id}])
          {user, orders}
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      {user, orders} = result
      assert user == %{id: "u1", name: "Alice"}
      assert orders == [%{id: "o1", user_id: "u1"}]
    end

    test "destructured tuple — independent bindings still batch" do
      # {:ok, a} and {:ok, b} are independent — should run concurrently.
      # c depends on both a and b.
      result =
        query do
          {:ok, a} <- Comp.pure({:ok, 10})
          {:ok, b} <- Comp.pure({:ok, 32})
          c <- Comp.pure(a + b)
          c
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "map pattern extracts variables that create dependencies" do
      result =
        query do
          %{name: name, id: uid} <- Comp.pure(%{name: "Alice", id: "u1"})
          greeting <- Comp.pure("Hello #{name}, your id is #{uid}")
          greeting
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == "Hello Alice, your id is u1"
    end

    test "nested destructuring extracts inner variables" do
      result =
        query do
          {:ok, %{user: %{id: uid}}} <- Comp.pure({:ok, %{user: %{id: "u1"}}})
          detail <- Comp.pure("user-#{uid}")
          detail
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == "user-u1"
    end

    test "list pattern extracts variables" do
      result =
        query do
          [first | _rest] <- Comp.pure([10, 20, 30])
          doubled <- Comp.pure(first * 2)
          doubled
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 20
    end

    test "struct pattern extracts variables" do
      result =
        query do
          %User{id: uid, name: uname} <- Comp.pure(%User{id: 1, name: "Alice"})
          label <- Comp.pure("#{uname}##{uid}")
          label
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == "Alice#1"
    end

    test "mixed destructured and simple bindings batch correctly" do
      # {:ok, a} and b are independent (batch 1).
      # c depends on a (from destructuring) and b (batch 2).
      result =
        query do
          {:ok, a} <- Comp.pure({:ok, 10})
          b <- Comp.pure(32)
          c <- Comp.pure(a + b)
          c
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end

    test "destructured pattern with Query.Contract dependency" do
      # Real contract integration: destructured result feeds into a dependent query
      with_test_pid(fn ->
        result =
          query do
            user <- TestQueries.get_user("1")
            {:ok, recent} <- Comp.pure({:ok, :some_recent_data})
            orders <- TestQueries.get_orders(user.id)
            {user, recent, orders}
          end
          |> TestQueries.with_executor(TestExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {user, recent, orders} = result
        assert %{id: "1", name: "User 1"} = user
        assert recent == :some_recent_data
        assert [%{id: "o1", user_id: "1"}] = orders

        # user and {:ok, recent} are independent (batch 1)
        # orders depends on user (batch 2)
        assert_received {:get_user_batch, 1}
        assert_received {:get_orders_batch, 1}
      end)
    end
  end

  describe "query — effects" do
    test "bindings can use State effect" do
      result =
        query do
          a <- State.get()
          b <- Comp.pure(a + 10)
          b
        end
        |> State.with_handler(32)
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end
  end

  describe "query — underscore bindings" do
    test "underscore binding for side-effect-only" do
      result =
        query do
          _ <- Comp.pure(:ignored)
          a <- Comp.pure(42)
          a
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end
  end

  describe "query — batching integration with Query.Contract" do
    test "independent queries are batched together" do
      with_test_pid(fn ->
        result =
          query do
            user <- TestQueries.get_user("1")
            recent <- TestQueries.get_recent()
            {user, recent}
          end
          |> TestQueries.with_executor(TestExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {user, recent} = result
        assert %{id: "1", name: "User 1"} = user
        assert [%{id: "recent1"}] = recent

        # Both should be batched (run concurrently in same round)
        assert_received {:get_user_batch, 1}
        assert_received {:get_recent_batch, 1}
      end)
    end

    test "dependent queries run in separate rounds" do
      with_test_pid(fn ->
        result =
          query do
            user <- TestQueries.get_user("1")
            orders <- TestQueries.get_orders(user.id)
            {user, orders}
          end
          |> TestQueries.with_executor(TestExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {user, orders} = result
        assert %{id: "1", name: "User 1"} = user
        assert [%{id: "o1", user_id: "1"}] = orders

        assert_received {:get_user_batch, 1}
        assert_received {:get_orders_batch, 1}
      end)
    end

    test "motivating example: user + recent concurrent, orders dependent" do
      with_test_pid(fn ->
        result =
          query do
            user <- TestQueries.get_user("1")
            recent <- TestQueries.get_recent()
            orders <- TestQueries.get_orders(user.id)
            {user, recent, orders}
          end
          |> TestQueries.with_executor(TestExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {user, recent, orders} = result
        assert %{id: "1", name: "User 1"} = user
        assert [%{id: "recent1"}] = recent
        assert [%{id: "o1", user_id: "1"}] = orders

        # user and recent should be in the same batch round
        assert_received {:get_user_batch, 1}
        assert_received {:get_recent_batch, 1}
        # orders comes after (depends on user)
        assert_received {:get_orders_batch, 1}
      end)
    end

    test "multiple users fetched concurrently" do
      with_test_pid(fn ->
        result =
          query do
            u1 <- TestQueries.get_user("1")
            u2 <- TestQueries.get_user("2")
            u3 <- TestQueries.get_user("3")
            {u1, u2, u3}
          end
          |> TestQueries.with_executor(TestExecutor)
          |> FiberPool.with_handler()
          |> Comp.run!()

        {u1, u2, u3} = result
        assert %{id: "1"} = u1
        assert %{id: "2"} = u2
        assert %{id: "3"} = u3

        # All 3 should be batched into a single executor call
        assert_received {:get_user_batch, 3}
      end)
    end
  end

  describe "query — compile errors" do
    test "empty block raises CompileError" do
      assert_raise CompileError, ~r/must contain at least one expression/, fn ->
        capture_io(:stderr, fn ->
          Code.compile_string("""
          import Skuld.Query.QueryBlock
          query do
          end
          """)
        end)
      end
    end

    test "single binding (no final expression) raises CompileError" do
      # Single `<-` in a do block is a single expression, which Elixir's
      # parser rejects before the macro runs (`<-` is not a standalone expr).
      assert_raise CompileError, fn ->
        capture_io(:stderr, fn ->
          Code.compile_string("""
          import Skuld.Query.QueryBlock
          query do
            a <- Skuld.Comp.pure(42)
          end
          """)
        end)
      end
    end

    test "ending with a <- binding raises CompileError" do
      # Multiple bindings with no final expression — caught by the macro's
      # own validation (not the Elixir parser).
      assert_raise CompileError, ~r/must end with an expression, not a binding/, fn ->
        capture_io(:stderr, fn ->
          Code.compile_string("""
          import Skuld.Query.QueryBlock
          query do
            a <- Skuld.Comp.pure(42)
            b <- Skuld.Comp.pure(a)
          end
          """)
        end)
      end
    end

    test "ending with an = assignment raises CompileError" do
      assert_raise CompileError, ~r/must end with an expression, not an assignment/, fn ->
        capture_io(:stderr, fn ->
          Code.compile_string("""
          import Skuld.Query.QueryBlock
          query do
            a <- Skuld.Comp.pure(42)
            b = a + 1
          end
          """)
        end)
      end
    end

    test "bare expression in middle raises CompileError" do
      assert_raise CompileError, ~r/bare expression in query block/, fn ->
        capture_io(:stderr, fn ->
          Code.compile_string("""
          import Skuld.Query.QueryBlock
          query do
            a <- Skuld.Comp.pure(42)
            IO.puts("hello")
            a
          end
          """)
        end)
      end
    end
  end

  describe "query — return helper" do
    test "return/1 works in query blocks" do
      result =
        query do
          a <- Comp.pure(42)
          return(a)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert result == 42
    end
  end
end
