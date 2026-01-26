defmodule Skuld.Effects.NonBlockingAsync.Scheduler.ServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  use Skuld.Syntax

  alias Skuld.Effects.NonBlockingAsync
  alias Skuld.Effects.NonBlockingAsync.Scheduler.Server
  alias Skuld.Effects.Throw

  describe "start_link/1" do
    test "starts with no computations" do
      {:ok, server} = Server.start_link()
      stats = Server.stats(server)
      assert stats.suspended == 0
      assert stats.ready == 0
      assert stats.completed == 0
      Server.stop(server)
    end

    test "starts with initial computations" do
      test_pid = self()
      comp1 = make_notifying_comp(test_pid, :comp1, :result1)
      comp2 = make_notifying_comp(test_pid, :comp2, :result2)

      {:ok, server} = Server.start_link(computations: [comp1, comp2])

      # Wait for both completion signals
      assert_receive {:completed, :comp1, :result1}, 1000
      assert_receive {:completed, :comp2, :result2}, 1000

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
      test_pid = self()

      comp = make_notifying_comp(test_pid, :my_comp, :my_result)
      {:ok, tag} = Server.spawn(server, comp)

      assert is_reference(tag)

      # Wait for completion signal
      assert_receive {:completed, :my_comp, :my_result}, 1000

      {:ok, result} = Server.get_result(server, tag)
      assert result == :my_result

      Server.stop(server)
    end

    test "spawns multiple computations" do
      {:ok, server} = Server.start_link()
      test_pid = self()

      {:ok, tag1} = Server.spawn(server, make_notifying_comp(test_pid, :first, :first))
      {:ok, tag2} = Server.spawn(server, make_notifying_comp(test_pid, :second, :second))
      {:ok, tag3} = Server.spawn(server, make_notifying_comp(test_pid, :third, :third))

      # Wait for all completion signals
      assert_receive {:completed, :first, :first}, 1000
      assert_receive {:completed, :second, :second}, 1000
      assert_receive {:completed, :third, :third}, 1000

      assert {:ok, :first} = Server.get_result(server, tag1)
      assert {:ok, :second} = Server.get_result(server, tag2)
      assert {:ok, :third} = Server.get_result(server, tag3)

      Server.stop(server)
    end
  end

  describe "spawn/3 with custom tag" do
    test "uses provided tag" do
      {:ok, server} = Server.start_link()
      test_pid = self()

      comp = make_notifying_comp(test_pid, :my_comp, :my_result)
      {:ok, :my_tag} = Server.spawn(server, comp, :my_tag)

      # Wait for completion signal
      assert_receive {:completed, :my_comp, :my_result}, 1000

      {:ok, result} = Server.get_result(server, :my_tag)
      assert result == :my_result

      Server.stop(server)
    end
  end

  describe "stats/1" do
    test "returns correct counts" do
      {:ok, server} = Server.start_link()

      # Initially empty
      stats = Server.stats(server)
      assert stats.suspended == 0
      assert stats.ready == 0
      assert stats.completed == 0

      # Spawn a computation that waits for a signal
      test_pid = self()

      {:ok, _tag} =
        Server.spawn(server, make_signaled_comp(test_pid, :waiting_comp, :slow_result))

      # Should be suspended waiting for signal
      assert_receive {:ready, :waiting_comp}, 1000
      stats = Server.stats(server)
      assert stats.suspended == 1

      # Signal to proceed and wait for completion
      send_signal(:waiting_comp)
      assert_receive {:completed, :waiting_comp, :slow_result}, 1000

      stats = Server.stats(server)
      assert stats.completed == 1

      Server.stop(server)
    end
  end

  describe "get_result/2" do
    test "returns result for completed computation" do
      {:ok, server} = Server.start_link()
      test_pid = self()

      {:ok, tag} = Server.spawn(server, make_notifying_comp(test_pid, :done_comp, :done))
      assert_receive {:completed, :done_comp, :done}, 1000

      assert {:ok, :done} = Server.get_result(server, tag)

      Server.stop(server)
    end

    test "returns pending for running computation" do
      {:ok, server} = Server.start_link()
      test_pid = self()

      {:ok, tag} = Server.spawn(server, make_signaled_comp(test_pid, :pending_test, :result))

      # Wait for it to be ready (suspended on signal)
      assert_receive {:ready, :pending_test}, 1000

      # Check immediately - should be pending
      result = Server.get_result(server, tag)
      assert result in [{:pending, :suspended}, {:pending, :ready}]

      # Clean up - signal to complete
      send_signal(:pending_test)
      assert_receive {:completed, :pending_test, :result}, 1000

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
      test_pid = self()

      {:ok, _tag1} = Server.spawn(server, make_notifying_comp(test_pid, :a, :a), :tag_a)
      {:ok, _tag2} = Server.spawn(server, make_notifying_comp(test_pid, :b, :b), :tag_b)

      # Wait for completions
      assert_receive {:completed, :a, :a}, 1000
      assert_receive {:completed, :b, :b}, 1000

      results = Server.get_all_results(server)

      assert results[:tag_a] == :a
      assert results[:tag_b] == :b

      Server.stop(server)
    end

    test "excludes pending computations" do
      {:ok, server} = Server.start_link()
      test_pid = self()

      {:ok, _} = Server.spawn(server, make_notifying_comp(test_pid, :fast, :fast), :fast)
      {:ok, _} = Server.spawn(server, make_signaled_comp(test_pid, :slow_test, :slow), :slow)

      # Wait for fast to complete and slow to be ready (suspended)
      assert_receive {:completed, :fast, :fast}, 1000
      assert_receive {:ready, :slow_test}, 1000

      results = Server.get_all_results(server)

      assert results[:fast] == :fast
      refute Map.has_key?(results, :slow)

      # Clean up
      send_signal(:slow_test)
      assert_receive {:completed, :slow_test, :slow}, 1000

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
      test_pid = self()

      {:ok, _} = Server.spawn(server, make_signaled_comp(test_pid, :active_test, :result))

      assert_receive {:ready, :active_test}, 1000
      assert Server.active?(server)

      # Clean up
      send_signal(:active_test)
      assert_receive {:completed, :active_test, :result}, 1000

      Server.stop(server)
    end

    test "false when all complete" do
      {:ok, server} = Server.start_link()
      test_pid = self()

      {:ok, _} = Server.spawn(server, make_notifying_comp(test_pid, :done, :done))
      assert_receive {:completed, :done, :done}, 1000

      refute Server.active?(server)

      Server.stop(server)
    end
  end

  describe "error handling" do
    test "computation errors are recorded" do
      {:ok, server} = Server.start_link()
      test_pid = self()

      # Use make_notifying_comp pattern but with an error
      # The boundary's on_unawaited callback signals completion
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

              r <- NonBlockingAsync.await(h)
              _ = send(test_pid, {:completed, :error_test, r})
              r
            end,
            # on_unawaited callback - also signals when boundary completes (even with error)
            fn result, _unawaited ->
              send(test_pid, {:completed, :error_test, result})
              result
            end
          )
        end
        |> NonBlockingAsync.with_handler()
        |> Throw.with_handler()

      # Capture expected error log from :log_and_continue behavior
      capture_log(fn ->
        {:ok, tag} = Server.spawn(server, comp)

        # Poll for result instead of relying on callback
        result = poll_for_result(server, tag, 1000)
        assert match?({:ok, {:error, _}}, result)

        Server.stop(server)
      end)
    end
  end

  describe "interleaved execution" do
    test "multiple computations interleave" do
      {:ok, server} = Server.start_link()
      test_pid = self()

      # Spawn computations that signal when they start and wait for proceed
      {:ok, _t1} = Server.spawn(server, make_signaled_comp(test_pid, :a, :a), :a)
      {:ok, _t2} = Server.spawn(server, make_signaled_comp(test_pid, :b, :b), :b)
      {:ok, _t3} = Server.spawn(server, make_signaled_comp(test_pid, :c, :c), :c)

      # Wait for all to be ready (suspended on signals)
      assert_receive {:ready, :a}, 1000
      assert_receive {:ready, :b}, 1000
      assert_receive {:ready, :c}, 1000

      # Signal all to proceed
      send_signal(:a)
      send_signal(:b)
      send_signal(:c)

      # Wait for all to complete
      assert_receive {:completed, :a, :a}, 1000
      assert_receive {:completed, :b, :b}, 1000
      assert_receive {:completed, :c, :c}, 1000

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

  # Poll for result using message round-trip to yield (not time-based).
  # Each iteration does a GenServer call which ensures the server has processed messages.
  defp poll_for_result(server, tag, max_attempts) when max_attempts > 0 do
    case Server.get_result(server, tag) do
      {:ok, _} = result ->
        result

      {:pending, _} ->
        # Do a stats call to yield and let server process messages
        _ = Server.stats(server)
        poll_for_result(server, tag, max_attempts - 1)

      {:error, :not_found} ->
        # Do a stats call to yield
        _ = Server.stats(server)
        poll_for_result(server, tag, max_attempts - 1)
    end
  end

  defp poll_for_result(_server, tag, 0) do
    {:error, {:timeout, tag}}
  end

  # Send a signal to a waiting computation
  # Receives the task pid from the {:task_pid, signal_name, task_pid} message
  defp send_signal(signal_name) do
    receive do
      {:task_pid, ^signal_name, task_pid} ->
        send(task_pid, {:signal, signal_name})
    end
  end

  # Create a computation that notifies on completion
  defp make_notifying_comp(test_pid, name, result) do
    comp do
      NonBlockingAsync.boundary(
        comp do
          h <-
            NonBlockingAsync.async(
              comp do
                result
              end
            )

          r <- NonBlockingAsync.await(h)
          _ = send(test_pid, {:completed, name, r})
          r
        end
      )
    end
    |> NonBlockingAsync.with_handler()
    |> Throw.with_handler()
  end

  # Create a computation that signals when ready and waits for a proceed signal
  # Also notifies on completion
  defp make_signaled_comp(test_pid, signal_name, result) do
    comp do
      NonBlockingAsync.boundary(
        comp do
          h <-
            NonBlockingAsync.async(
              comp do
                # Signal that we're ready and send our pid for signaling back
                _ = send(test_pid, {:ready, signal_name})
                _ = send(test_pid, {:task_pid, signal_name, self()})

                # Wait for proceed signal
                _ =
                  receive do
                    {:signal, ^signal_name} -> :ok
                  end

                result
              end
            )

          r <- NonBlockingAsync.await(h)
          _ = send(test_pid, {:completed, signal_name, r})
          r
        end
      )
    end
    |> NonBlockingAsync.with_handler()
    |> Throw.with_handler()
  end
end
