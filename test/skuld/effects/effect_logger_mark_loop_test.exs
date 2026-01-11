defmodule Skuld.Effects.EffectLoggerMarkLoopTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.EffectLogger
  alias Skuld.Effects.EffectLogger.Log
  alias Skuld.Effects.State

  describe "Log.build_loop_hierarchy/1" do
    test "empty log has empty hierarchy" do
      log = Log.new()
      assert Log.build_loop_hierarchy(log) == %{}
    end

    test "single loop has nil parent" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()

      hierarchy = Log.build_loop_hierarchy(log)
      assert hierarchy == %{TestLoop => nil}
    end

    test "nested loops have correct parent-child relationships" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(OuterLoop)
          _ <- EffectLogger.mark_loop(MiddleLoop)
          _ <- EffectLogger.mark_loop(InnerLoop)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()

      hierarchy = Log.build_loop_hierarchy(log)
      assert hierarchy == %{OuterLoop => nil, MiddleLoop => OuterLoop, InnerLoop => MiddleLoop}
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
        |> EffectLogger.with_logging()
        |> Comp.run()

      hierarchy = Log.build_loop_hierarchy(log)
      assert hierarchy == %{OuterLoop => nil, InnerLoop => OuterLoop}
    end
  end

  describe "Log.is_ancestor?/3" do
    test "returns false for same loop_id" do
      hierarchy = %{A => nil, B => A, C => B}
      refute Log.is_ancestor?(hierarchy, A, A)
      refute Log.is_ancestor?(hierarchy, B, B)
    end

    test "returns true for direct parent" do
      hierarchy = %{A => nil, B => A, C => B}
      assert Log.is_ancestor?(hierarchy, A, B)
      assert Log.is_ancestor?(hierarchy, B, C)
    end

    test "returns true for transitive ancestor" do
      hierarchy = %{A => nil, B => A, C => B}
      assert Log.is_ancestor?(hierarchy, A, C)
    end

    test "returns false for non-ancestor" do
      hierarchy = %{A => nil, B => A, C => B}
      refute Log.is_ancestor?(hierarchy, C, A)
      refute Log.is_ancestor?(hierarchy, B, A)
    end

    test "returns false for unrelated loops" do
      hierarchy = %{A => nil, B => nil}
      refute Log.is_ancestor?(hierarchy, A, B)
      refute Log.is_ancestor?(hierarchy, B, A)
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
    test "no pruning with single mark" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 1})
          _ <- State.put(100)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # With only one mark, nothing to prune
      assert length(entries_before) == length(entries_after)
    end

    test "prunes completed iteration" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 1})
          _ <- State.put(100)
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 2})
          _ <- State.put(200)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # Before: Mark1, Put100, Mark2, Put200 (4 entries)
      # After: Mark2, Put200 (2 entries) - first iteration pruned
      assert length(entries_before) == 4
      assert length(entries_after) == 2
    end

    test "prunes multiple completed iterations" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 1})
          _ <- State.put(100)
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 2})
          _ <- State.put(200)
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 3})
          _ <- State.put(300)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # Before: 6 entries (3 marks + 3 puts)
      # After: 2 entries (Mark3, Put300) - iterations 1 and 2 pruned
      assert length(entries_before) == 6
      assert length(entries_after) == 2
    end
  end

  describe "Log.prune_completed_loops/1 - nested loops" do
    test "inner loop pruning respects outer loop boundaries" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(OuterLoop, %{outer: 1})
          _ <- EffectLogger.mark_loop(InnerLoop, %{inner: 1})
          _ <- State.put(10)
          _ <- EffectLogger.mark_loop(InnerLoop, %{inner: 2})
          _ <- State.put(20)
          _ <- EffectLogger.mark_loop(OuterLoop, %{outer: 2})
          _ <- EffectLogger.mark_loop(InnerLoop, %{inner: 1})
          _ <- State.put(30)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # Original: Outer1, Inner1, Put10, Inner2, Put20, Outer2, Inner1, Put30
      # Inner loop pruning: Inner1->Inner2 range pruned (within first outer iteration)
      # Outer loop pruning: Outer1->Outer2 range pruned
      # Result should keep: Outer2, Inner1, Put30

      assert length(entries_before) == 8
      assert length(entries_after) == 3

      # Verify the remaining entries are from the last iteration
      [outer_mark, inner_mark, put_entry] = entries_after
      assert outer_mark.data.checkpoint == %{outer: 2}
      assert inner_mark.data.checkpoint == %{inner: 1}
      # State.put returns a Change struct
      assert %Skuld.Data.Change{} = put_entry.value
    end

    test "three-level nesting prunes correctly" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(L1, %{l1: 1})
          _ <- EffectLogger.mark_loop(L2, %{l2: 1})
          _ <- EffectLogger.mark_loop(L3, %{l3: 1})
          _ <- State.put(1)
          _ <- EffectLogger.mark_loop(L3, %{l3: 2})
          _ <- State.put(2)
          _ <- EffectLogger.mark_loop(L1, %{l1: 2})
          _ <- EffectLogger.mark_loop(L2, %{l2: 1})
          _ <- EffectLogger.mark_loop(L3, %{l3: 1})
          _ <- State.put(3)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      entries_before = Log.to_list(log)
      pruned = Log.prune_completed_loops(log)
      entries_after = Log.to_list(pruned)

      # Should keep only the last outer iteration: L1(2), L2(1), L3(1), Put3
      assert length(entries_before) == 10
      assert length(entries_after) == 4
    end
  end

  describe "Log.extract_loop_checkpoints/1" do
    test "extracts most recent checkpoint for each loop" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(OuterLoop, %{outer: 1})
          _ <- EffectLogger.mark_loop(InnerLoop, %{inner: 1})
          _ <- EffectLogger.mark_loop(InnerLoop, %{inner: 2})
          _ <- EffectLogger.mark_loop(OuterLoop, %{outer: 2})
          _ <- EffectLogger.mark_loop(InnerLoop, %{inner: 3})
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()

      checkpoints = Log.extract_loop_checkpoints(log)

      assert checkpoints == %{
               OuterLoop => %{outer: 2},
               InnerLoop => %{inner: 3}
             }
    end
  end

  describe "EffectLogger with prune_loops option" do
    test "prune_loops: true prunes on finalization" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 1})
          _ <- State.put(100)
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 2})
          _ <- State.put(200)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: true)
        |> State.with_handler(0)
        |> Comp.run()

      entries = Log.to_list(log)
      # Only last iteration remains
      assert length(entries) == 2
    end

    test "prune_loops: false (default) preserves all entries" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 1})
          _ <- State.put(100)
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 2})
          _ <- State.put(200)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      entries = Log.to_list(log)
      # All entries preserved
      assert length(entries) == 4
    end
  end

  describe "replay with pruned log" do
    test "pruned log can be replayed" do
      # First run with pruning
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 1})
          s1 <- State.get()
          _ <- State.put(s1 + 10)
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 2})
          s2 <- State.get()
          _ <- State.put(s2 + 20)
          return(:done)
        end
        |> EffectLogger.with_logging(prune_loops: true)
        |> State.with_handler(0)
        |> Comp.run()

      # Verify pruned
      assert length(Log.to_list(log)) == 3

      # Replay the pruned log - this replays only the last iteration
      {{:done, _replay_log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 1})
          s1 <- State.get()
          _ <- State.put(s1 + 10)
          _ <- EffectLogger.mark_loop(TestLoop, %{iter: 2})
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

  describe "JSON serialization of mark_loop entries" do
    test "mark_loop entries serialize and deserialize correctly" do
      {{:done, log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, %{messages: ["hello"], count: 42})
          _ <- State.put(100)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Serialize to JSON
      json = Jason.encode!(log)

      # Deserialize
      restored = json |> Jason.decode!() |> Log.from_json()

      # Verify entries are preserved
      entries = Log.to_list(restored)
      assert length(entries) == 2

      [mark_entry, _state_entry] = entries
      assert mark_entry.sig == Skuld.Effects.EffectLogger
      assert mark_entry.data.loop_id == TestLoop
      # After JSON round-trip, map keys are strings
      assert mark_entry.data.checkpoint == %{"messages" => ["hello"], "count" => 42}
    end
  end
end
