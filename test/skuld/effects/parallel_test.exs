defmodule Skuld.Effects.ParallelTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Parallel
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

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
      result =
        comp do
          Parallel.all([
            comp do
              Process.sleep(30)
              :slow
            end,
            comp do
              Process.sleep(10)
              :fast
            end,
            comp do
              Process.sleep(20)
              :medium
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      # Results in input order, not completion order
      assert result == [:slow, :fast, :medium]
    end

    test "runs concurrently" do
      start_time = System.monotonic_time(:millisecond)

      result =
        comp do
          Parallel.all([
            comp do
              Process.sleep(50)
              :a
            end,
            comp do
              Process.sleep(50)
              :b
            end,
            comp do
              Process.sleep(50)
              :c
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert result == [:a, :b, :c]
      # Parallel: ~50ms. Sequential would be ~150ms
      assert elapsed < 120
    end

    test "task failure returns error" do
      result =
        comp do
          Parallel.all([
            comp do
              :ok
            end,
            comp do
              raise "boom!"
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
      result =
        comp do
          Parallel.race([
            comp do
              Process.sleep(100)
              :slow
            end,
            comp do
              Process.sleep(10)
              :fast
            end,
            comp do
              Process.sleep(50)
              :medium
            end
          ])
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

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
      result =
        comp do
          Parallel.race([
            comp do
              raise "fail fast"
            end,
            comp do
              Process.sleep(20)
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
              raise "boom1"
            end,
            comp do
              raise "boom2"
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

      # Define helper functions to avoid nested comp macro issues
      # (nested comps with statements trigger macro expansion bugs)
      slow_work = fn ->
        Process.sleep(100)
        Agent.update(agent, &[:slow | &1])
        :slow
      end

      fast_work = fn ->
        Process.sleep(10)
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

      # Give a moment for any stragglers
      Process.sleep(150)

      completed = Agent.get(agent, & &1)
      Agent.stop(agent)

      # Only :fast should have completed
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
      result =
        comp do
          Parallel.map([3, 1, 2], fn x ->
            comp do
              Process.sleep(x * 10)
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
      start_time = System.monotonic_time(:millisecond)

      result =
        comp do
          Parallel.map([1, 2, 3], fn x ->
            comp do
              Process.sleep(50)
              x
            end
          end)
        end
        |> Parallel.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert result == [1, 2, 3]
      assert elapsed < 120
    end

    test "task failure returns error" do
      result =
        comp do
          Parallel.map([1, 2, 3], fn x ->
            comp do
              if x == 2, do: raise("boom!")
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
              raise "boom!"
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
              raise "boom!"
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
              if x == 2, do: raise("boom!")
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
