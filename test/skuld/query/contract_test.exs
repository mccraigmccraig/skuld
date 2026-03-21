defmodule Skuld.Query.ContractTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.FiberPool
  alias Skuld.Effects.Throw
  alias Skuld.Fiber.FiberPool.BatchExecutor

  # ---------------------------------------------------------------
  # Test contract modules — defined at compile time
  # ---------------------------------------------------------------

  defmodule User do
    defstruct [:id, :name, :org_id]
  end

  defmodule Post do
    defstruct [:id, :title, :user_id]
  end

  defmodule TestQueries do
    use Skuld.Query.Contract

    deffetch(get_user(id :: String.t()) :: User.t() | nil)
    deffetch(get_users_by_org(org_id :: String.t()) :: [User.t()])
    deffetch(get_user_count(org_id :: String.t()) :: non_neg_integer())
  end

  defmodule OkErrorQueries do
    use Skuld.Query.Contract

    deffetch(find_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()})
    deffetch(find_post(id :: String.t()) :: Post.t() | nil, bang: false)
    deffetch(find_item(id :: String.t()) :: term(), bang: true)
  end

  defmodule CustomBangQueries do
    use Skuld.Query.Contract

    deffetch(find_user(id :: String.t()) :: User.t() | nil,
      bang: fn
        nil -> {:error, :not_found}
        user -> {:ok, user}
      end
    )
  end

  defmodule PostQueries do
    use Skuld.Query.Contract

    deffetch(get_post(id :: String.t()) :: Post.t() | nil)
    deffetch(get_posts_by_user(user_id :: String.t()) :: [Post.t()])
  end

  defmodule ZeroArgQueries do
    use Skuld.Query.Contract

    deffetch(health_check() :: :ok)
  end

  defmodule CacheOptQueries do
    use Skuld.Query.Contract

    deffetch(get_user(id :: String.t()) :: User.t() | nil)
    deffetch(get_random() :: term(), cache: false)
    deffetch(get_explicit_cached(id :: String.t()) :: term(), cache: true)
  end

  # ---------------------------------------------------------------
  # Test executor — implements the TestQueries.Executor behaviour
  # ---------------------------------------------------------------

  defmodule TestExecutor do
    @behaviour TestQueries.Executor

    @impl true
    def get_user(ops) do
      Comp.pure(
        Map.new(ops, fn {ref, %TestQueries.GetUser{id: id}} ->
          {ref, %User{id: id, name: "User #{id}"}}
        end)
      )
    end

    @impl true
    def get_users_by_org(ops) do
      Comp.pure(
        Map.new(ops, fn {ref, %TestQueries.GetUsersByOrg{org_id: org_id}} ->
          {ref,
           [
             %User{id: "#{org_id}-1", name: "User A", org_id: org_id},
             %User{id: "#{org_id}-2", name: "User B", org_id: org_id}
           ]}
        end)
      )
    end

    @impl true
    def get_user_count(ops) do
      Comp.pure(
        Map.new(ops, fn {ref, %TestQueries.GetUserCount{org_id: _org_id}} ->
          {ref, 42}
        end)
      )
    end
  end

  defmodule PostExecutor do
    @behaviour PostQueries.Executor

    @impl true
    def get_post(ops) do
      Comp.pure(
        Map.new(ops, fn {ref, %PostQueries.GetPost{id: id}} ->
          {ref, %Post{id: id, title: "Post #{id}"}}
        end)
      )
    end

    @impl true
    def get_posts_by_user(ops) do
      Comp.pure(
        Map.new(ops, fn {ref, %PostQueries.GetPostsByUser{user_id: user_id}} ->
          {ref, [%Post{id: "#{user_id}-p1", title: "Post 1", user_id: user_id}]}
        end)
      )
    end
  end

  # =====================================================================
  # Tests
  # =====================================================================

  describe "compilation and struct generation" do
    test "contract module compiles and generates struct modules" do
      # Struct modules exist
      assert Code.ensure_loaded?(TestQueries.GetUser)
      assert Code.ensure_loaded?(TestQueries.GetUsersByOrg)
      assert Code.ensure_loaded?(TestQueries.GetUserCount)
    end

    test "struct modules have correct fields" do
      user_op = %TestQueries.GetUser{id: "123"}
      assert user_op.id == "123"

      org_op = %TestQueries.GetUsersByOrg{org_id: "org-1"}
      assert org_op.org_id == "org-1"

      count_op = %TestQueries.GetUserCount{org_id: "org-1"}
      assert count_op.org_id == "org-1"
    end

    test "struct modules have correct default values" do
      user_op = %TestQueries.GetUser{}
      assert user_op.id == nil
    end

    test "zero-arg query generates empty struct" do
      assert Code.ensure_loaded?(ZeroArgQueries.HealthCheck)
      op = %ZeroArgQueries.HealthCheck{}
      assert op == %ZeroArgQueries.HealthCheck{}
    end
  end

  describe "executor behaviour" do
    test "Executor behaviour module exists" do
      assert Code.ensure_loaded?(TestQueries.Executor)
    end

    test "executor module compiles with @behaviour" do
      # TestExecutor implements all callbacks — if it compiled, the behaviour works
      assert Code.ensure_loaded?(TestExecutor)
    end
  end

  describe "caller functions produce correct suspensions" do
    test "caller returns a computation function" do
      comp = TestQueries.get_user("123")
      assert is_function(comp, 2)
    end

    test "caller produces InternalSuspend with correct batch key and op" do
      comp = TestQueries.get_user("123")

      env = Skuld.Comp.Env.new()
      k = fn result, e -> {result, e} end

      {suspend, _env} = comp.(env, k)

      assert %Skuld.Comp.InternalSuspend{
               payload: %Skuld.Comp.InternalSuspend.Batch{
                 batch_key: {TestQueries, :get_user},
                 op: %TestQueries.GetUser{id: "123"},
                 request_id: ref
               }
             } = suspend

      assert is_reference(ref)
    end
  end

  describe "batching integration" do
    test "single query via fiber pool works" do
      result =
        comp do
          h <- FiberPool.fiber(TestQueries.get_user("1"))
          FiberPool.await!(h)
        end
        |> TestQueries.with_executor(TestExecutor)
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert %User{id: "1", name: "User 1"} = result
    end

    test "multiple queries of same type are batched" do
      test_pid = self()

      counting_executor = %{
        __struct__: TestExecutor,
        get_user: fn ops ->
          send(test_pid, {:batch_size, length(ops)})

          Comp.pure(
            Map.new(ops, fn {ref, %TestQueries.GetUser{id: id}} ->
              {ref, %User{id: id, name: "User #{id}"}}
            end)
          )
        end
      }

      # Use direct BatchExecutor registration instead of with_executor
      # to inject our counting executor
      result =
        comp do
          h1 <- FiberPool.fiber(TestQueries.get_user("1"))
          h2 <- FiberPool.fiber(TestQueries.get_user("2"))
          h3 <- FiberPool.fiber(TestQueries.get_user("3"))
          FiberPool.await_all!([h1, h2, h3])
        end
        |> BatchExecutor.with_executor(
          {TestQueries, :get_user},
          counting_executor.get_user
        )
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert_received {:batch_size, 3}

      assert [
               %User{id: "1", name: "User 1"},
               %User{id: "2", name: "User 2"},
               %User{id: "3", name: "User 3"}
             ] = result
    end

    test "different query types batch separately" do
      test_pid = self()

      user_executor = fn ops ->
        send(test_pid, {:user_batch, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %TestQueries.GetUser{id: id}} ->
            {ref, %User{id: id, name: "User #{id}"}}
          end)
        )
      end

      count_executor = fn ops ->
        send(test_pid, {:count_batch, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, _op} ->
            {ref, 42}
          end)
        )
      end

      result =
        comp do
          h1 <- FiberPool.fiber(TestQueries.get_user("1"))
          h2 <- FiberPool.fiber(TestQueries.get_user_count("org-1"))
          FiberPool.await_all!([h1, h2])
        end
        |> BatchExecutor.with_executor({TestQueries, :get_user}, user_executor)
        |> BatchExecutor.with_executor({TestQueries, :get_user_count}, count_executor)
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert_received {:user_batch, 1}
      assert_received {:count_batch, 1}

      assert [%User{id: "1"}, 42] = result
    end
  end

  describe "with_executor/2" do
    test "installs executor for all queries in the contract" do
      result =
        comp do
          h1 <- FiberPool.fiber(TestQueries.get_user("1"))
          h2 <- FiberPool.fiber(TestQueries.get_users_by_org("org-1"))
          h3 <- FiberPool.fiber(TestQueries.get_user_count("org-1"))
          FiberPool.await_all!([h1, h2, h3])
        end
        |> TestQueries.with_executor(TestExecutor)
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert [
               %User{id: "1", name: "User 1"},
               [%User{org_id: "org-1"}, %User{org_id: "org-1"}],
               42
             ] = result
    end
  end

  describe "with_executors/2 bulk wiring" do
    test "list of tuples variant works" do
      result =
        comp do
          h1 <- FiberPool.fiber(TestQueries.get_user("1"))
          h2 <- FiberPool.fiber(PostQueries.get_post("p1"))
          FiberPool.await_all!([h1, h2])
        end
        |> Skuld.Query.Contract.with_executors([
          {TestQueries, TestExecutor},
          {PostQueries, PostExecutor}
        ])
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert [%User{id: "1"}, %Post{id: "p1"}] = result
    end

    test "map variant works" do
      result =
        comp do
          h1 <- FiberPool.fiber(TestQueries.get_user("1"))
          h2 <- FiberPool.fiber(PostQueries.get_post("p1"))
          FiberPool.await_all!([h1, h2])
        end
        |> Skuld.Query.Contract.with_executors(%{
          TestQueries => TestExecutor,
          PostQueries => PostExecutor
        })
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert [%User{id: "1"}, %Post{id: "p1"}] = result
    end
  end

  describe "multi-contract batching" do
    test "two different contracts' queries don't interfere" do
      test_pid = self()

      user_exec = fn ops ->
        send(test_pid, {:user_exec, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %TestQueries.GetUser{id: id}} ->
            {ref, %User{id: id, name: "User #{id}"}}
          end)
        )
      end

      post_exec = fn ops ->
        send(test_pid, {:post_exec, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %PostQueries.GetPost{id: id}} ->
            {ref, %Post{id: id, title: "Post #{id}"}}
          end)
        )
      end

      result =
        comp do
          h1 <- FiberPool.fiber(TestQueries.get_user("1"))
          h2 <- FiberPool.fiber(PostQueries.get_post("p1"))
          h3 <- FiberPool.fiber(TestQueries.get_user("2"))
          h4 <- FiberPool.fiber(PostQueries.get_post("p2"))
          FiberPool.await_all!([h1, h2, h3, h4])
        end
        |> BatchExecutor.with_executor({TestQueries, :get_user}, user_exec)
        |> BatchExecutor.with_executor({PostQueries, :get_post}, post_exec)
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert_received {:user_exec, 2}
      assert_received {:post_exec, 2}

      assert [
               %User{id: "1"},
               %Post{id: "p1"},
               %User{id: "2"},
               %Post{id: "p2"}
             ] = result
    end
  end

  describe "__dispatch__/3" do
    test "routes to correct executor callback" do
      ops = [{make_ref(), %TestQueries.GetUser{id: "1"}}]
      result = TestQueries.__dispatch__(TestExecutor, :get_user, ops) |> Comp.run!()

      [{_ref, user}] = Map.to_list(result)
      assert %User{id: "1", name: "User 1"} = user
    end
  end

  describe "__query_operations__/0" do
    test "returns correct metadata for all queries" do
      ops = TestQueries.__query_operations__()

      assert length(ops) == 3

      get_user_op = Enum.find(ops, &(&1.name == :get_user))
      assert get_user_op.params == [:id]
      assert get_user_op.arity == 1

      get_users_op = Enum.find(ops, &(&1.name == :get_users_by_org))
      assert get_users_op.params == [:org_id]
      assert get_users_op.arity == 1

      count_op = Enum.find(ops, &(&1.name == :get_user_count))
      assert count_op.params == [:org_id]
      assert count_op.arity == 1
    end

    test "cacheable defaults to true" do
      ops = TestQueries.__query_operations__()

      Enum.each(ops, fn op ->
        assert op.cacheable == true, "Expected #{op.name} to have cacheable: true"
      end)
    end

    test "cache: false sets cacheable to false" do
      ops = CacheOptQueries.__query_operations__()

      random_op = Enum.find(ops, &(&1.name == :get_random))
      assert random_op.cacheable == false
    end

    test "cache: true (explicit) sets cacheable to true" do
      ops = CacheOptQueries.__query_operations__()

      explicit_op = Enum.find(ops, &(&1.name == :get_explicit_cached))
      assert explicit_op.cacheable == true
    end

    test "default and explicit cache options coexist in same contract" do
      ops = CacheOptQueries.__query_operations__()

      assert length(ops) == 3

      get_user_op = Enum.find(ops, &(&1.name == :get_user))
      assert get_user_op.cacheable == true

      random_op = Enum.find(ops, &(&1.name == :get_random))
      assert random_op.cacheable == false

      explicit_op = Enum.find(ops, &(&1.name == :get_explicit_cached))
      assert explicit_op.cacheable == true
    end
  end

  describe "bang variants" do
    test "auto-detected bang for {:ok, T} return type" do
      # OkErrorQueries.find_user has {:ok, User.t()} | {:error, term()}
      # Should auto-generate find_user!/1
      assert function_exported?(OkErrorQueries, :find_user!, 1)
    end

    test "bang: false suppresses bang generation" do
      # OkErrorQueries.find_post has bang: false
      refute function_exported?(OkErrorQueries, :find_post!, 1)
    end

    test "bang: true forces bang generation" do
      # OkErrorQueries.find_item has bang: true
      assert function_exported?(OkErrorQueries, :find_item!, 1)
    end

    test "no bang generated for non-ok-error return types" do
      # TestQueries.get_user returns User.t() | nil — no {:ok, T}
      refute function_exported?(TestQueries, :get_user!, 1)
    end

    test "standard bang unwraps :ok and returns value" do
      ok_executor = fn ops ->
        Comp.pure(
          Map.new(ops, fn {ref, _op} ->
            {ref, {:ok, %User{id: "1", name: "Found"}}}
          end)
        )
      end

      result =
        comp do
          h <- FiberPool.fiber(OkErrorQueries.find_user!("1"))
          FiberPool.await!(h)
        end
        |> BatchExecutor.with_executor({OkErrorQueries, :find_user}, ok_executor)
        |> Throw.with_handler()
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert %User{id: "1", name: "Found"} = result
    end

    test "standard bang throws on :error" do
      error_executor = fn ops ->
        Comp.pure(
          Map.new(ops, fn {ref, _op} ->
            {ref, {:error, :not_found}}
          end)
        )
      end

      # Bang dispatches Throw inside the fiber, causing fiber failure.
      # Without a Throw handler in the fiber, the effect raises.
      assert_raise RuntimeError, ~r/Fiber failed/, fn ->
        comp do
          h <- FiberPool.fiber(OkErrorQueries.find_user!("1"))
          FiberPool.await!(h)
        end
        |> BatchExecutor.with_executor({OkErrorQueries, :find_user}, error_executor)
        |> FiberPool.with_handler()
        |> Comp.run!()
      end
    end

    test "custom bang unwrap function works" do
      found_executor = fn ops ->
        Comp.pure(
          Map.new(ops, fn {ref, _op} ->
            {ref, %User{id: "1", name: "Found"}}
          end)
        )
      end

      # non-nil → :ok via custom unwrap — should succeed
      ok_result =
        comp do
          h <- FiberPool.fiber(CustomBangQueries.find_user!("1"))
          FiberPool.await!(h)
        end
        |> BatchExecutor.with_executor({CustomBangQueries, :find_user}, found_executor)
        |> FiberPool.with_handler()
        |> Comp.run!()

      assert %User{id: "1", name: "Found"} = ok_result
    end

    test "custom bang unwrap function throws on nil" do
      nil_executor = fn ops ->
        Comp.pure(Map.new(ops, fn {ref, _op} -> {ref, nil} end))
      end

      # nil → custom unwrap → {:error, :not_found} → Throw.throw
      # Since it's inside a fiber, the fiber will fail
      assert_raise RuntimeError, ~r/Fiber failed/, fn ->
        comp do
          h <- FiberPool.fiber(CustomBangQueries.find_user!("1"))
          FiberPool.await!(h)
        end
        |> BatchExecutor.with_executor({CustomBangQueries, :find_user}, nil_executor)
        |> FiberPool.with_handler()
        |> Comp.run!()
      end
    end
  end

  describe "error cases" do
    test "missing executor raises error" do
      assert_raise RuntimeError, ~r/no_batch_executor/, fn ->
        comp do
          h <- FiberPool.fiber(TestQueries.get_user("1"))
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> Comp.run!()
      end
    end

    test "invalid deffetch syntax raises CompileError" do
      assert_raise CompileError, fn ->
        Code.compile_string("""
        defmodule BadQuery do
          use Skuld.Query.Contract

          deffetch not_valid_syntax
        end
        """)
      end
    end

    test "no deffetch declarations raises CompileError" do
      assert_raise CompileError, ~r/has no deffetch declarations/, fn ->
        Code.compile_string("""
        defmodule EmptyContract do
          use Skuld.Query.Contract
        end
        """)
      end
    end
  end

  describe "PascalCase conversion" do
    test "to_pascal_case converts snake_case atoms" do
      assert Skuld.Query.Contract.to_pascal_case(:get_user) == :GetUser
      assert Skuld.Query.Contract.to_pascal_case(:get_users_by_org) == :GetUsersByOrg
      assert Skuld.Query.Contract.to_pascal_case(:health_check) == :HealthCheck
      assert Skuld.Query.Contract.to_pascal_case(:a) == :A
    end
  end
end
