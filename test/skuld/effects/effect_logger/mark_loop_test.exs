defmodule Skuld.Effects.EffectLogger.MarkLoopTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.EffectLogger
  alias Skuld.Effects.EffectLogger.Log
  alias Skuld.Effects.State

  # Recursive computations for testing pruning
  defcomp countdown(n) do
    _ <- EffectLogger.mark_loop(CountdownLoop)
    current <- State.get()
    _ <- State.put(current + 1)

    result <-
      if n > 0 do
        countdown(n - 1)
      else
        State.get()
      end

    return(result)
  end

  defcomp nested_loops(outer, inner) do
    _ <- EffectLogger.mark_loop(OuterLoop)
    _ <- State.put({:outer, outer})

    result <-
      if outer > 0 do
        comp do
          _ <- inner_loop(inner)
          nested_loops(outer - 1, inner)
        end
      else
        Comp.pure(:done)
      end

    return(result)
  end

  defcomp inner_loop(n) do
    _ <- EffectLogger.mark_loop(InnerLoop)
    {tag, val} <- State.get()
    _ <- State.put({tag, val + 1})

    result <-
      if n > 0 do
        inner_loop(n - 1)
      else
        Comp.pure(:inner_done)
      end

    return(result)
  end

  describe "EffectLogger.mark_loop/1" do
    test "returns :ok when handled" do
      {{:done, _log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()
    end

    test "accepts any atom as loop_id" do
      {{:done, _log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(:my_loop)
          _ <- EffectLogger.mark_loop(SomeModule)
          _ <- EffectLogger.mark_loop(:"Elixir.AnotherModule")
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()
    end

    test "allows multiple marks of the same loop_id" do
      {{:done, _log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- EffectLogger.mark_loop(TestLoop)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()
    end

    test "allows nested marks of different loop_ids" do
      {{:done, _log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()
    end
  end

  describe "Log.build_loop_hierarchy/1" do
    test "empty log has empty hierarchy" do
      log = Log.new()
      assert Log.build_loop_hierarchy(log) == %{}
    end

    test "single loop has :__root__ as parent" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()

      hierarchy = Log.build_loop_hierarchy(log)
      assert hierarchy == %{:__root__ => nil, TestLoop => :__root__}
    end

    test "nested loops have correct parent-child relationships with :__root__" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(MiddleLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: false)
        |> Comp.run()

      hierarchy = Log.build_loop_hierarchy(log)

      assert hierarchy == %{
               :__root__ => nil,
               OuterLoop => :__root__,
               MiddleLoop => OuterLoop,
               InnerLoop => MiddleLoop
             }
    end

    test "repeated marks maintain hierarchy" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: false)
        |> Comp.run()

      hierarchy = Log.build_loop_hierarchy(log)
      assert hierarchy == %{:__root__ => nil, OuterLoop => :__root__, InnerLoop => OuterLoop}
    end
  end

  describe "Log.ancestor?/3" do
    test "returns false for same loop_id" do
      hierarchy = %{A => nil, B => A, C => B}
      refute Log.ancestor?(hierarchy, A, A)
      refute Log.ancestor?(hierarchy, B, B)
    end

    test "returns true for direct parent" do
      hierarchy = %{A => nil, B => A, C => B}
      assert Log.ancestor?(hierarchy, A, B)
      assert Log.ancestor?(hierarchy, B, C)
    end

    test "returns true for transitive ancestor" do
      hierarchy = %{A => nil, B => A, C => B}
      assert Log.ancestor?(hierarchy, A, C)
    end

    test "returns false for non-ancestor" do
      hierarchy = %{A => nil, B => A, C => B}
      refute Log.ancestor?(hierarchy, C, A)
      refute Log.ancestor?(hierarchy, B, A)
    end

    test "returns false for unrelated loops" do
      hierarchy = %{A => nil, B => nil}
      refute Log.ancestor?(hierarchy, A, B)
      refute Log.ancestor?(hierarchy, B, A)
    end
  end

  describe "Log.ancestors/2" do
    test "root has no ancestors" do
      hierarchy = %{A => nil, B => A, C => B}
      assert Log.ancestors(hierarchy, A) == []
    end

    test "returns ancestors closest first" do
      hierarchy = %{A => nil, B => A, C => B}
      assert Log.ancestors(hierarchy, C) == [B, A]
      assert Log.ancestors(hierarchy, B) == [A]
    end
  end

  describe "Log.prune_completed_loops/1 - single loop" do
    test "no pruning with single mark (plus root)" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(100)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # With only one mark per loop (root + TestLoop), nothing to prune
      assert length(entries_before) == length(entries_after)
    end

    test "prunes completed iteration (keeps root + last iteration)" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(100)
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(200)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # Before: Root, Mark1, Put100, Mark2, Put200 (5 entries)
      # After: Root, Mark2, Put200 (3 entries) - first iteration pruned
      assert length(entries_before) == 5
      assert length(entries_after) == 3
    end

    test "prunes multiple completed iterations" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(100)
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(200)
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(300)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # Before: 7 entries (root + 3 marks + 3 puts)
      # After: 3 entries (Root, Mark3, Put300) - iterations 1 and 2 pruned
      assert length(entries_before) == 7
      assert length(entries_after) == 3
    end
  end

  describe "Log.prune_completed_loops/1 - nested loops" do
    test "inner loop pruning respects outer loop boundaries" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          _ <- State.put(10)
          _ <- EffectLogger.mark_loop(InnerLoop)
          _ <- State.put(20)
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          _ <- State.put(30)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # Original: Root, Outer1, Inner1, Put10, Inner2, Put20, Outer2, Inner1, Put30 (9)
      # After pruning: Root, Outer2, Inner1, Put30 (4)
      assert length(entries_before) == 9
      assert length(entries_after) == 4

      # Verify the remaining entries are from the last iteration
      [_root, outer_mark, inner_mark, put_entry] = entries_after
      assert outer_mark.data.loop_id == OuterLoop
      assert inner_mark.data.loop_id == InnerLoop
      assert %Skuld.Data.Change{} = put_entry.value
    end

    test "three-level nesting prunes correctly" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(L1)
          _ <- EffectLogger.mark_loop(L2)
          _ <- EffectLogger.mark_loop(L3)
          _ <- State.put(1)
          _ <- EffectLogger.mark_loop(L3)
          _ <- State.put(2)
          _ <- EffectLogger.mark_loop(L1)
          _ <- EffectLogger.mark_loop(L2)
          _ <- EffectLogger.mark_loop(L3)
          _ <- State.put(3)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # Before: 11 (root + 6 marks + 3 puts + 1 extra from second iteration)
      # After: Root, L1(2), L2(1), L3(1), Put3 = 5 entries
      assert length(entries_before) == 11
      assert length(entries_after) == 5
    end
  end

  describe "Log.extract_loop_checkpoints/1" do
    test "extracts most recent env_state for each loop" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()

      checkpoints = Log.extract_loop_checkpoints(log)

      # Should have :__root__, OuterLoop, InnerLoop
      assert Map.has_key?(checkpoints, :__root__)
      assert Map.has_key?(checkpoints, OuterLoop)
      assert Map.has_key?(checkpoints, InnerLoop)
      # Each checkpoint should be a map (the env.state)
      assert is_map(checkpoints[:__root__])
    end
  end

  describe "EffectLogger with prune_loops option" do
    test "prune_loops: true (default) prunes eagerly on mark_loop" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(100)
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(200)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: true)
        |> State.with_handler(0)
        |> Comp.run()

      entries = Log.to_list(log)
      # Only root + last iteration remains: Root, Mark2, Put200 = 3
      assert length(entries) == 3
    end

    test "prune_loops: false preserves all entries" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(100)
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(200)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler(0)
        |> Comp.run()

      entries = Log.to_list(log)
      # All entries preserved: Root, Mark1, Put100, Mark2, Put200 = 5
      assert length(entries) == 5
    end

    test "default prune_loops: true prunes eagerly" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(100)
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(200)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      entries = Log.to_list(log)
      # Default is prune_loops: true, so only root + last iteration: 3 entries
      assert length(entries) == 3
    end
  end

  describe "replay with pruned log" do
    test "pruned log can be replayed" do
      # First run with pruning
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          s1 <- State.get()
          _ <- State.put(s1 + 10)
          _ <- EffectLogger.mark_loop(TestLoop)
          s2 <- State.get()
          _ <- State.put(s2 + 20)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: true)
        |> State.with_handler(0)
        |> Comp.run()

      # Verify pruned (Root + Mark2 + Get + Put = 4)
      # With eager pruning, only last iteration remains
      assert length(Log.to_list(log)) == 4

      # Replay the pruned log - this replays only the last iteration
      {{:done, _replay_log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          s1 <- State.get()
          _ <- State.put(s1 + 10)
          _ <- EffectLogger.mark_loop(TestLoop)
          s2 <- State.get()
          _ <- State.put(s2 + 20)
          return(:done)
        end
        |> EffectLogger.with_logging(log, allow_divergence: true)
        |> State.with_handler(0)
        |> Comp.run()

      # Should complete successfully
    end
  end

  describe "pruning with recursive computations" do
    test "prunes completed iterations in recursive countdown loop" do
      # Run countdown from 3 to 0 (4 iterations total)
      {{result, log}, _env} =
        countdown(3)
        |> EffectLogger.with_logging(prune_loops: true)
        |> State.with_handler(0)
        |> Comp.run()

      # Final state should be 4 (incremented once per iteration)
      assert result == 4

      entries = Log.to_list(log)

      # Count how many CountdownLoop marks remain (should be 1 - only last iteration)
      loop_marks =
        Enum.filter(entries, fn e ->
          e.sig == EffectLogger and match?(%{loop_id: CountdownLoop}, e.data)
        end)

      assert length(loop_marks) == 1

      # With eager pruning, only the last iteration's effects remain
      # Last iteration (n=0): mark, get, put, get (final) = 4 effects, plus root = 5
      # But eager pruning happens after each mark, so structure may differ
      # Key assertion: log is small and has only 1 loop mark
      assert length(entries) <= 5
    end

    test "without pruning, all iterations are preserved" do
      # Run same countdown without pruning
      {{result, log}, _env} =
        countdown(3)
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler(0)
        |> Comp.run()

      assert result == 4

      entries = Log.to_list(log)

      # All 4 CountdownLoop marks should be present
      loop_marks =
        Enum.filter(entries, fn e ->
          e.sig == EffectLogger and match?(%{loop_id: CountdownLoop}, e.data)
        end)

      assert length(loop_marks) == 4

      # Total: root + 4*(mark + get + put) + final_get = 1 + 12 + 1 = 14
      assert length(entries) == 14
    end

    test "nested recursive loops prune correctly" do
      # 2 outer iterations (outer=1, outer=0), inner loop runs only when outer > 0
      # So we get: outer=1 with inner iterations, then outer=0 (no inner)
      {{result, log}, _env} =
        nested_loops(1, 1)
        |> EffectLogger.with_logging(prune_loops: true)
        |> State.with_handler({:init, 0})
        |> Comp.run()

      assert result == :done

      entries = Log.to_list(log)

      # After pruning: only last outer iteration remains
      # The last outer iteration (outer=0) has no inner loop
      outer_marks =
        Enum.filter(entries, fn e ->
          e.sig == EffectLogger and match?(%{loop_id: OuterLoop}, e.data)
        end)

      # Should have 1 outer mark after pruning (the final iteration)
      assert length(outer_marks) == 1

      # Verify this is fewer entries than without pruning
      {{_result2, log2}, _env2} =
        nested_loops(1, 1)
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler({:init, 0})
        |> Comp.run()

      # Pruned log should be smaller
      assert length(Log.to_list(log)) < length(Log.to_list(log2))
    end

    test "state is correctly accumulated across pruned iterations" do
      # Verify that even though iterations are pruned, the result reflects all work done
      {{result, log}, _env} =
        countdown(5)
        |> EffectLogger.with_logging(prune_loops: true)
        |> State.with_handler(100)
        |> Comp.run()

      # Started at 100, incremented 6 times (iterations 5,4,3,2,1,0)
      assert result == 106

      # Log should be small (pruned) compared to all iterations
      entries = Log.to_list(log)

      # Count marks - should only have 1 CountdownLoop mark
      loop_marks =
        Enum.filter(entries, fn e ->
          e.sig == EffectLogger and match?(%{loop_id: CountdownLoop}, e.data)
        end)

      assert length(loop_marks) == 1

      # Verify it's much smaller than unpruned
      {{_result2, log2}, _env2} =
        countdown(5)
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler(100)
        |> Comp.run()

      assert length(entries) < length(Log.to_list(log2))
    end
  end

  describe "JSON serialization of mark_loop entries" do
    test "mark_loop entries serialize and deserialize correctly" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          _ <- State.put(100)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: false)
        |> State.with_handler(0)
        |> Comp.run()

      # Serialize to JSON
      json = Jason.encode!(log)

      # Deserialize
      restored = json |> Jason.decode!() |> Log.from_json()

      # Verify entries are preserved (Root + Mark + Put = 3)
      entries = Log.to_list(restored)
      assert length(entries) == 3

      [root_entry, mark_entry, _state_entry] = entries
      assert root_entry.sig == Skuld.Effects.EffectLogger
      assert root_entry.data.loop_id == :__root__
      assert mark_entry.sig == Skuld.Effects.EffectLogger
      assert mark_entry.data.loop_id == TestLoop
      # env_state should be a map
      assert is_map(mark_entry.data.env_state)
    end
  end

  describe "env.state capture and restore" do
    test "mark_loop captures current env.state" do
      {{:done, log}, _env} =
        comp do
          _ <- State.put(42)
          _ <- EffectLogger.mark_loop(TestLoop)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Find the TestLoop mark entry
      entries = Log.to_list(log)

      mark_entry =
        Enum.find(entries, fn e ->
          e.sig == Skuld.Effects.EffectLogger and
            match?(%{loop_id: TestLoop}, e.data)
        end)

      # The env_state should contain the State effect's state key
      assert is_map(mark_entry.data.env_state)
    end

    test "root mark captures initial env.state" do
      {{:done, log}, _env} =
        comp do
          _ <- State.get()
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(42)
        |> Comp.run()

      # Find the root mark entry
      entries = Log.to_list(log)

      root_entry =
        Enum.find(entries, fn e ->
          e.sig == Skuld.Effects.EffectLogger and
            match?(%{loop_id: :__root__}, e.data)
        end)

      assert root_entry != nil
      assert is_map(root_entry.data.env_state)
    end
  end
end
