defmodule Skuld.Effects.NonBlockingAsync.Scheduler.ServerTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Effects.NonBlockingAsync
  alias Skuld.Effects.NonBlockingAsync.Scheduler.Server
  alias Skuld.Effects.Throw

  describe "start_link/1" do
    test "starts with no computations" do
      {:ok, server} = Server.start_link()
      assert Server.stats(server) == %{suspended: 0, ready: 0, completed: 0}
      Server.stop(server)
    end

    test "starts with initial computations" do
      comp1 = make_async_comp(:result1)
      comp2 = make_async_comp(:result2)

      {:ok, server} = Server.start_link(computations: [comp1, comp2])

      # Allow tasks to complete
      Process.sleep(10)

      stats = Server.stats(server)
      assert stats.completed == 2

      Server.stop(server)
    end

    test "accepts name option" do
      {:ok, _server} = Server.start_link(name: :test_scheduler_server)

      stats = Server.stats(:test_scheduler_server)
      assert is_map(stats)

      Server.stop(:test_scheduler_server)
    end
  end

  describe "spawn/2" do
    test "spawns computation and returns tag" do
      {:ok, server} = Server.start_link()

      comp = make_async_comp(:my_result)
      {:ok, tag} = Server.spawn(server, comp)

      assert is_reference(tag)

      # Allow task to complete
      Process.sleep(10)

      {:ok, result} = Server.get_result(server, tag)
      assert result == :my_result

      Server.stop(server)
    end

    test "spawns multiple computations" do
      {:ok, server} = Server.start_link()

      {:ok, tag1} = Server.spawn(server, make_async_comp(:first))
      {:ok, tag2} = Server.spawn(server, make_async_comp(:second))
      {:ok, tag3} = Server.spawn(server, make_async_comp(:third))

      # Allow tasks to complete
      Process.sleep(20)

      assert {:ok, :first} = Server.get_result(server, tag1)
      assert {:ok, :second} = Server.get_result(server, tag2)
      assert {:ok, :third} = Server.get_result(server, tag3)

      Server.stop(server)
    end
  end

  describe "spawn/3 with custom tag" do
    test "uses provided tag" do
      {:ok, server} = Server.start_link()

      comp = make_async_comp(:my_result)
      {:ok, :my_tag} = Server.spawn(server, comp, :my_tag)

      # Allow task to complete
      Process.sleep(10)

      {:ok, result} = Server.get_result(server, :my_tag)
      assert result == :my_result

      Server.stop(server)
    end
  end

  describe "stats/1" do
    test "returns correct counts" do
      {:ok, server} = Server.start_link()

      # Initially empty
      assert Server.stats(server) == %{suspended: 0, ready: 0, completed: 0}

      # Spawn a computation that takes some time
      {:ok, _tag} = Server.spawn(server, make_slow_async_comp(:slow, 100))

      # Should be suspended waiting for task
      stats = Server.stats(server)
      assert stats.suspended == 1 or stats.completed == 1

      Server.stop(server)
    end
  end

  describe "get_result/2" do
    test "returns result for completed computation" do
      {:ok, server} = Server.start_link()

      {:ok, tag} = Server.spawn(server, make_async_comp(:done))
      Process.sleep(10)

      assert {:ok, :done} = Server.get_result(server, tag)

      Server.stop(server)
    end

    test "returns pending for running computation" do
      {:ok, server} = Server.start_link()

      {:ok, tag} = Server.spawn(server, make_slow_async_comp(:slow, 500))

      # Check immediately - should be pending
      result = Server.get_result(server, tag)
      assert result in [{:pending, :suspended}, {:pending, :ready}]

      Server.stop(server)
    end

    test "returns not_found for unknown tag" do
      {:ok, server} = Server.start_link()

      assert {:error, :not_found} = Server.get_result(server, :unknown_tag)

      Server.stop(server)
    end
  end

  describe "get_all_results/1" do
    test "returns all completed results" do
      {:ok, server} = Server.start_link()

      {:ok, _tag1} = Server.spawn(server, make_async_comp(:a), :tag_a)
      {:ok, _tag2} = Server.spawn(server, make_async_comp(:b), :tag_b)

      Process.sleep(20)

      results = Server.get_all_results(server)

      assert results[:tag_a] == :a
      assert results[:tag_b] == :b

      Server.stop(server)
    end

    test "excludes pending computations" do
      {:ok, server} = Server.start_link()

      {:ok, _} = Server.spawn(server, make_async_comp(:fast), :fast)
      {:ok, _} = Server.spawn(server, make_slow_async_comp(:slow, 500), :slow)

      Process.sleep(20)

      results = Server.get_all_results(server)

      # Fast should be complete, slow should not be in results
      assert results[:fast] == :fast
      refute Map.has_key?(results, :slow)

      Server.stop(server)
    end
  end

  describe "active?/1" do
    test "false when no computations" do
      {:ok, server} = Server.start_link()
      refute Server.active?(server)
      Server.stop(server)
    end

    test "true when computations are running" do
      {:ok, server} = Server.start_link()

      {:ok, _} = Server.spawn(server, make_slow_async_comp(:slow, 500))

      assert Server.active?(server)

      Server.stop(server)
    end

    test "false when all complete" do
      {:ok, server} = Server.start_link()

      {:ok, _} = Server.spawn(server, make_async_comp(:done))
      Process.sleep(20)

      refute Server.active?(server)

      Server.stop(server)
    end
  end

  describe "error handling" do
    test "computation errors are recorded" do
      {:ok, server} = Server.start_link()

      comp =
        comp do
          NonBlockingAsync.boundary(
            comp do
              h <-
                NonBlockingAsync.async(
                  comp do
                    # Use if to suppress "never matches" warning
                    _ = if true, do: raise("boom"), else: :ok
                    :never_reached
                  end
                )

              NonBlockingAsync.await(h)
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()

      {:ok, tag} = Server.spawn(server, comp)
      Process.sleep(20)

      {:ok, result} = Server.get_result(server, tag)
      assert match?({:error, _}, result)

      Server.stop(server)
    end
  end

  describe "interleaved execution" do
    test "multiple computations interleave" do
      {:ok, server} = Server.start_link()

      # Spawn several computations with varying delays
      {:ok, _t1} = Server.spawn(server, make_slow_async_comp(:a, 10), :a)
      {:ok, _t2} = Server.spawn(server, make_slow_async_comp(:b, 20), :b)
      {:ok, _t3} = Server.spawn(server, make_slow_async_comp(:c, 15), :c)

      # Wait for all to complete
      Process.sleep(50)

      results = Server.get_all_results(server)
      assert results[:a] == :a
      assert results[:b] == :b
      assert results[:c] == :c

      Server.stop(server)
    end
  end

  #############################################################################
  ## Test Helpers
  #############################################################################

  # Create a computation that does an async operation and returns a result
  defp make_async_comp(result) do
    comp do
      NonBlockingAsync.boundary(
        comp do
          h <-
            NonBlockingAsync.async(
              comp do
                result
              end
            )

          NonBlockingAsync.await(h)
        end
      )
    end
    |> NonBlockingAsync.with_handler()
    |> Throw.with_handler()
  end

  # Create a computation with a delay
  defp make_slow_async_comp(result, delay_ms) do
    comp do
      NonBlockingAsync.boundary(
        comp do
          h <-
            NonBlockingAsync.async(
              comp do
                _ = Process.sleep(delay_ms)
                result
              end
            )

          NonBlockingAsync.await(h)
        end
      )
    end
    |> NonBlockingAsync.with_handler()
    |> Throw.with_handler()
  end
end
