defmodule Skuld.Effects.ParallelTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Parallel
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  # Helper to raise without triggering "typing violation" warnings.
  # Must be public (def) since parallel tasks run in separate processes.
  def boom!(msg \\ "boom!") do
    if true, do: raise(msg), else: :ok
  end

  # Barrier for testing concurrency - tasks signal arrival and wait for release
  defmodule Barrier do
    def start(n) do
      {:ok, agent} = Agent.start_link(fn -> {0, n, []} end)
      agent
    end

    def arrive_and_wait(barrier) do
      self_pid = self()

      Agent.update(barrier, fn {count, n, waiters} ->
        {count + 1, n, [self_pid | waiters]}
      end)

      {count, n, waiters} = Agent.get(barrier, & &1)

      if count >= n do
        Enum.each(waiters, &send(&1, :released))
      end

      receive do
        :released -> :ok
      after
        1000 -> raise "Barrier timeout - not all tasks arrived"
      end
    end

    def stop(barrier), do: Agent.stop(barrier)
  end

  # Latch for controlling task ordering - tasks wait until released
  defmodule Latch do
    def start do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      agent
    end

    def wait(latch) do
      self_pid = self()
      Agent.update(latch, fn waiters -> [self_pid | waiters] end)

      receive do
        :released -> :ok
      after
        1000 -> raise "Latch timeout"
      end
    end

    def release(latch) do
      waiters = Agent.get(latch, & &1)
      Enum.each(waiters, &send(&1, :released))
    end

    def stop(latch), do: Agent.stop(latch)
  end

  describe "with_handler all/1" do
    test "runs multiple computations and returns all results" do
      result =
        comp do
          Parallel.all([
            comp do
              :a
            end,
            comp do
              :b
            end,
            comp do
              :c
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == [:a, :b, :c]
    end

    test "empty list returns empty list" do
      result =
        comp do
          Parallel.all([])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == []
    end

    test "single computation works" do
      result =
        comp do
          Parallel.all([
            comp do
              :only_one
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == [:only_one]
    end

    test "preserves order of results" do
      # Simply verify results are in input order regardless of any execution timing
      result =
        comp do
          Parallel.all([
            comp do
              :first
            end,
            comp do
              :second
            end,
            comp do
              :third
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == [:first, :second, :third]
    end

    test "runs concurrently" do
      # Use a barrier to prove all 3 tasks run concurrently
      # If they were sequential, the barrier would timeout
      barrier = Barrier.start(3)

      result =
        comp do
          Parallel.all([
            comp do
              _ = Barrier.arrive_and_wait(barrier)
              :a
            end,
            comp do
              _ = Barrier.arrive_and_wait(barrier)
              :b
            end,
            comp do
              _ = Barrier.arrive_and_wait(barrier)
              :c
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      Barrier.stop(barrier)

      assert result == [:a, :b, :c]
    end

    test "task failure returns error" do
      result =
        comp do
          Parallel.all([
            comp do
              :ok
            end,
            comp do
              boom!()
            end,
            comp do
              :also_ok
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert match?({:error, {:task_failed, _}}, result)
    end
  end

  describe "with_handler race/1" do
    test "returns first result" do
      # fast completes immediately, others block on latches (and get cancelled)
      latch_slow = Latch.start()
      latch_medium = Latch.start()

      result =
        comp do
          Parallel.race([
            comp do
              _ = Latch.wait(latch_slow)
              :slow
            end,
            comp do
              :fast
            end,
            comp do
              _ = Latch.wait(latch_medium)
              :medium
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      Latch.stop(latch_slow)
      Latch.stop(latch_medium)

      assert result == :fast
    end

    test "empty list returns error" do
      result =
        comp do
          Parallel.race([])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:error, :all_tasks_failed}
    end

    test "single computation returns its result" do
      result =
        comp do
          Parallel.race([
            comp do
              :only
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :only
    end

    test "ignores failed tasks if one succeeds" do
      # One task fails, one succeeds - race should return the success
      result =
        comp do
          Parallel.race([
            comp do
              boom!("fail fast")
            end,
            comp do
              :success
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == :success
    end

    test "returns error if all tasks fail" do
      result =
        comp do
          Parallel.race([
            comp do
              boom!("boom1")
            end,
            comp do
              boom!("boom2")
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:error, :all_tasks_failed}
    end

    test "cancels slower tasks" do
      # Use an agent to track which tasks complete
      {:ok, agent} = Agent.start_link(fn -> [] end)

      # slow_work blocks on a latch that never gets released (task gets cancelled)
      latch = Latch.start()

      slow_work = fn ->
        Latch.wait(latch)
        Agent.update(agent, &[:slow | &1])
        :slow
      end

      fast_work = fn ->
        Agent.update(agent, &[:fast | &1])
        :fast
      end

      _result =
        comp do
          Parallel.race([
            comp do
              slow_work.()
            end,
            comp do
              fast_work.()
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      completed = Agent.get(agent, & &1)
      Agent.stop(agent)
      Latch.stop(latch)

      # Only :fast should have completed (slow was cancelled)
      assert completed == [:fast]
    end
  end

  describe "with_handler map/2" do
    test "maps over items in parallel" do
      result =
        comp do
          Parallel.map([1, 2, 3], fn x ->
            comp do
              x * 2
            end
          end)
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == [2, 4, 6]
    end

    test "empty list returns empty list" do
      result =
        comp do
          Parallel.map([], fn x ->
            comp do
              x
            end
          end)
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == []
    end

    test "preserves order" do
      # Simply verify results are in input order
      result =
        comp do
          Parallel.map([3, 1, 2], fn x ->
            comp do
              x
            end
          end)
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == [3, 1, 2]
    end

    test "runs concurrently" do
      # Use a barrier to prove all 3 map tasks run concurrently
      barrier = Barrier.start(3)

      result =
        comp do
          Parallel.map([1, 2, 3], fn x ->
            comp do
              _ = Barrier.arrive_and_wait(barrier)
              x
            end
          end)
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      Barrier.stop(barrier)

      assert result == [1, 2, 3]
    end

    test "task failure returns error" do
      result =
        comp do
          Parallel.map([1, 2, 3], fn x ->
            comp do
              _ = if x == 2, do: raise("boom!")
              x
            end
          end)
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert match?({:error, {:task_failed, _}}, result)
    end
  end

  describe "with_sequential_handler all/1" do
    test "runs computations sequentially" do
      result =
        comp do
          Parallel.all([
            comp do
              :a
            end,
            comp do
              :b
            end,
            comp do
              :c
            end
          ])
        end
        |> Parallel.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == [:a, :b, :c]
    end

    test "empty list returns empty list" do
      result =
        comp do
          Parallel.all([])
        end
        |> Parallel.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == []
    end

    test "task failure returns error" do
      result =
        comp do
          Parallel.all([
            comp do
              :ok
            end,
            comp do
              boom!()
            end,
            comp do
              :also_ok
            end
          ])
        end
        |> Parallel.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert match?({:error, {:task_failed, _}}, result)
    end
  end

  describe "with_sequential_handler race/1" do
    test "returns first computation result" do
      result =
        comp do
          Parallel.race([
            comp do
              :first
            end,
            comp do
              :second
            end,
            comp do
              :third
            end
          ])
        end
        |> Parallel.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # Sequential race returns the first one
      assert result == :first
    end

    test "empty list returns error" do
      result =
        comp do
          Parallel.race([])
        end
        |> Parallel.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {:error, :all_tasks_failed}
    end

    test "task failure returns error" do
      result =
        comp do
          Parallel.race([
            comp do
              boom!()
            end,
            comp do
              :second
            end
          ])
        end
        |> Parallel.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # In sequential mode, first comp fails so we get error
      assert match?({:error, {:task_failed, _}}, result)
    end
  end

  describe "with_sequential_handler map/2" do
    test "maps over items sequentially" do
      result =
        comp do
          Parallel.map([1, 2, 3], fn x ->
            comp do
              x * 2
            end
          end)
        end
        |> Parallel.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == [2, 4, 6]
    end

    test "empty list returns empty list" do
      result =
        comp do
          Parallel.map([], fn x ->
            comp do
              x
            end
          end)
        end
        |> Parallel.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == []
    end

    test "task failure returns error" do
      result =
        comp do
          Parallel.map([1, 2, 3], fn x ->
            comp do
              _ = if x == 2, do: raise("boom!")
              x
            end
          end)
        end
        |> Parallel.with_sequential_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert match?({:error, {:task_failed, _}}, result)
    end
  end

  describe "state isolation" do
    test "child tasks get snapshot of parent state (production)" do
      result =
        comp do
          _ <- State.put(100)

          results <-
            Parallel.all([
              comp do
                # Should see 100 from parent
                State.get()
              end,
              comp do
                State.get()
              end
            ])

          parent_state <- State.get()
          {results, parent_state}
        end
        |> State.with_handler(0)
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == {[100, 100], 100}
    end

    test "child state changes don't propagate to parent (production)" do
      result =
        comp do
          _ <- State.put(100)

          _ <-
            Parallel.all([
              comp do
                _ <- State.put(999)
                :done
              end
            ])

          # Parent state should still be 100
          State.get()
        end
        |> State.with_handler(0)
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert result == 100
    end
  end
end
