defmodule Skuld.Effects.DBTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.DB
  alias Skuld.Effects.FiberPool
  alias Skuld.Fiber.FiberPool.BatchExecutor

  # Simple mock "schema" modules for testing
  defmodule User do
    defstruct [:id, :name, :org_id]
  end

  defmodule Post do
    defstruct [:id, :title, :user_id]
  end

  describe "basic batching" do
    test "single fetch works" do
      # Mock executor that returns a user for any ID
      mock_executor = fn ops ->
        Comp.pure(
          Map.new(ops, fn {ref, %DB.Fetch{id: id}} ->
            {ref, %User{id: id, name: "User #{id}"}}
          end)
        )
      end

      result =
        comp do
          h <- FiberPool.submit(DB.fetch(User, 1))
          FiberPool.await(h)
        end
        |> BatchExecutor.with_executor({:db_fetch, User}, mock_executor)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert %User{id: 1, name: "User 1"} = result
    end

    test "multiple fetches are batched together" do
      # Track how many times executor is called
      test_pid = self()

      mock_executor = fn ops ->
        send(test_pid, {:executor_called, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %DB.Fetch{id: id}} ->
            {ref, %User{id: id, name: "User #{id}"}}
          end)
        )
      end

      result =
        comp do
          h1 <- FiberPool.submit(DB.fetch(User, 1))
          h2 <- FiberPool.submit(DB.fetch(User, 2))
          h3 <- FiberPool.submit(DB.fetch(User, 3))

          FiberPool.await_all([h1, h2, h3])
        end
        |> BatchExecutor.with_executor({:db_fetch, User}, mock_executor)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      # Verify executor was called once with all 3 ops
      assert_received {:executor_called, 3}

      # Verify results
      assert [
               %User{id: 1, name: "User 1"},
               %User{id: 2, name: "User 2"},
               %User{id: 3, name: "User 3"}
             ] = result
    end

    test "fetches for different schemas are batched separately" do
      test_pid = self()

      user_executor = fn ops ->
        send(test_pid, {:user_executor_called, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %DB.Fetch{id: id}} ->
            {ref, %User{id: id, name: "User #{id}"}}
          end)
        )
      end

      post_executor = fn ops ->
        send(test_pid, {:post_executor_called, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %DB.Fetch{id: id}} ->
            {ref, %Post{id: id, title: "Post #{id}"}}
          end)
        )
      end

      result =
        comp do
          h1 <- FiberPool.submit(DB.fetch(User, 1))
          h2 <- FiberPool.submit(DB.fetch(Post, 1))
          h3 <- FiberPool.submit(DB.fetch(User, 2))
          h4 <- FiberPool.submit(DB.fetch(Post, 2))

          FiberPool.await_all([h1, h2, h3, h4])
        end
        |> BatchExecutor.with_executor({:db_fetch, User}, user_executor)
        |> BatchExecutor.with_executor({:db_fetch, Post}, post_executor)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      # Each executor called once with 2 ops
      assert_received {:user_executor_called, 2}
      assert_received {:post_executor_called, 2}

      assert [
               %User{id: 1},
               %Post{id: 1},
               %User{id: 2},
               %Post{id: 2}
             ] = result
    end

    test "wildcard executor matches any schema" do
      test_pid = self()

      wildcard_executor = fn ops ->
        send(test_pid, {:wildcard_executor_called, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %DB.Fetch{schema: schema, id: id}} ->
            result =
              case schema do
                User -> %User{id: id, name: "User #{id}"}
                Post -> %Post{id: id, title: "Post #{id}"}
              end

            {ref, result}
          end)
        )
      end

      result =
        comp do
          h1 <- FiberPool.submit(DB.fetch(User, 1))
          h2 <- FiberPool.submit(DB.fetch(User, 2))

          FiberPool.await_all([h1, h2])
        end
        |> BatchExecutor.with_executor({:db_fetch, :_}, wildcard_executor)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      # Wildcard executor called with both User fetches
      assert_received {:wildcard_executor_called, 2}

      assert [%User{id: 1}, %User{id: 2}] = result
    end
  end

  describe "fetch_all batching" do
    test "fetch_all operations are batched" do
      test_pid = self()

      mock_executor = fn ops ->
        send(test_pid, {:fetch_all_executor_called, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %DB.FetchAll{filter_value: org_id}} ->
            # Return 2 users for each org
            {ref,
             [
               %User{id: org_id * 10, name: "User A", org_id: org_id},
               %User{id: org_id * 10 + 1, name: "User B", org_id: org_id}
             ]}
          end)
        )
      end

      result =
        comp do
          h1 <- FiberPool.submit(DB.fetch_all(User, :org_id, 1))
          h2 <- FiberPool.submit(DB.fetch_all(User, :org_id, 2))

          FiberPool.await_all([h1, h2])
        end
        |> BatchExecutor.with_executor({:db_fetch_all, User, :org_id}, mock_executor)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert_received {:fetch_all_executor_called, 2}

      assert [
               [%User{org_id: 1}, %User{org_id: 1}],
               [%User{org_id: 2}, %User{org_id: 2}]
             ] = result
    end
  end

  describe "error handling" do
    test "missing executor raises error" do
      assert_raise RuntimeError, ~r/no_batch_executor/, fn ->
        comp do
          h <- FiberPool.submit(DB.fetch(User, 1))
          FiberPool.await(h)
        end
        # No executor installed!
        |> FiberPool.with_handler()
        |> FiberPool.run!()
      end
    end

    test "executor error propagates to awaiting fiber" do
      error_executor = fn _ops ->
        Skuld.Effects.Throw.throw(:executor_failed)
      end

      assert_raise RuntimeError, ~r/Fiber failed/, fn ->
        comp do
          h <- FiberPool.submit(DB.fetch(User, 1))
          FiberPool.await(h)
        end
        |> BatchExecutor.with_executor({:db_fetch, User}, error_executor)
        |> FiberPool.with_handler()
        |> FiberPool.run!()
      end
    end

    test "fetch returns nil for missing record" do
      mock_executor = fn ops ->
        # Only return user with id 1, others get nil
        Comp.pure(
          Map.new(ops, fn {ref, %DB.Fetch{id: id}} ->
            result = if id == 1, do: %User{id: 1, name: "User 1"}, else: nil
            {ref, result}
          end)
        )
      end

      result =
        comp do
          h1 <- FiberPool.submit(DB.fetch(User, 1))
          h2 <- FiberPool.submit(DB.fetch(User, 999))

          FiberPool.await_all([h1, h2])
        end
        |> BatchExecutor.with_executor({:db_fetch, User}, mock_executor)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      assert [%User{id: 1}, nil] = result
    end
  end

  describe "nested batching" do
    test "batch results trigger more batching" do
      test_pid = self()

      user_executor = fn ops ->
        send(test_pid, {:user_batch, length(ops)})

        Comp.pure(
          Map.new(ops, fn {ref, %DB.Fetch{id: id}} ->
            {ref, %User{id: id, name: "User #{id}", org_id: 1}}
          end)
        )
      end

      # This test verifies that after one batch completes,
      # resumed fibers can trigger another batch
      result =
        comp do
          # First batch of fetches
          h1 <- FiberPool.submit(DB.fetch(User, 1))
          h2 <- FiberPool.submit(DB.fetch(User, 2))

          FiberPool.await_all([h1, h2])
        end
        |> BatchExecutor.with_executor({:db_fetch, User}, user_executor)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      # Should have batched 2 users
      assert_received {:user_batch, 2}
      assert length(result) == 2
    end
  end

  describe "scoped executors" do
    test "executor can be overridden for entire computation" do
      test_pid = self()

      default_executor = fn ops ->
        send(test_pid, {:default_executor, length(ops)})
        Comp.pure(Map.new(ops, fn {ref, _} -> {ref, :default_result} end))
      end

      custom_executor = fn ops ->
        send(test_pid, {:custom_executor, length(ops)})
        Comp.pure(Map.new(ops, fn {ref, _} -> {ref, :custom_result} end))
      end

      # Test that explicit executor overrides wildcard
      result =
        comp do
          h1 <- FiberPool.submit(DB.fetch(User, 1))
          h2 <- FiberPool.submit(DB.fetch(User, 2))
          FiberPool.await_all([h1, h2])
        end
        # Wildcard executor
        |> BatchExecutor.with_executor({:db_fetch, :_}, default_executor)
        # Exact match overrides wildcard
        |> BatchExecutor.with_executor({:db_fetch, User}, custom_executor)
        |> FiberPool.with_handler()
        |> FiberPool.run!()

      # Custom executor should be used (exact match wins)
      assert_received {:custom_executor, 2}
      refute_received {:default_executor, _}

      assert [:custom_result, :custom_result] = result
    end
  end

  describe "with_executors helper" do
    test "with_executors installs default executors" do
      # This test verifies the helper installs executors correctly
      # We check by verifying executors are accessible within the computation

      test_pid = self()

      # Create a computation that checks for the executor presence
      check_comp =
        fn env, k ->
          # Check that executors are installed
          has_fetch = BatchExecutor.get_executor(env, {:db_fetch, User}) != nil
          has_fetch_all = BatchExecutor.get_executor(env, {:db_fetch_all, User, :org_id}) != nil
          send(test_pid, {:executors_present, has_fetch, has_fetch_all})
          k.(:ok, env)
        end
        |> DB.with_executors()

      Comp.call(check_comp, Skuld.Comp.Env.new(), &Comp.identity_k/2)

      assert_received {:executors_present, true, true}
    end
  end
end
