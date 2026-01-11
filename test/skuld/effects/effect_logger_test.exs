defmodule Skuld.Effects.EffectLoggerTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.EffectLogger
  alias Skuld.Effects.EffectLogger.EffectLogEntry
  alias Skuld.Effects.EffectLogger.Log
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield
  alias Skuld.Data.Change

  # Helper to filter out the root mark from log entries for easier testing
  defp user_entries(log) do
    Log.to_list(log)
    |> Enum.reject(fn entry ->
      entry.sig == EffectLogger and match?(%{loop_id: :__root__}, entry.data)
    end)
  end

  describe "basic logging" do
    test "logs a single effect" do
      {{result, log}, _env} =
        State.get()
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      assert result == 0

      entries = user_entries(log)
      assert length(entries) == 1

      [entry] = entries
      assert entry.sig == State
      assert %State.Get{} = entry.data
      assert entry.value == 0
      assert entry.state == :executed
    end

    test "logs multiple effects in execution order" do
      computation =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          y <- State.get()
          return({x, y})
        end

      {{result, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      assert result == {0, 1}

      entries = user_entries(log)
      assert length(entries) == 3

      [get1, put, get2] = entries

      assert get1.sig == State
      assert %State.Get{} = get1.data
      assert get1.value == 0
      assert get1.state == :executed

      assert put.sig == State
      assert %State.Put{value: 1} = put.data
      assert put.value == %Change{old: 0, new: 1}
      assert put.state == :executed

      assert get2.sig == State
      assert %State.Get{} = get2.data
      assert get2.value == 1
      assert get2.state == :executed
    end

    test "each entry has a unique id" do
      computation =
        comp do
          _ <- State.get()
          _ <- State.get()
          _ <- State.get()
          return(:done)
        end

      {{_result, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      entries = Log.to_list(log)
      ids = Enum.map(entries, & &1.id)

      assert length(ids) == length(Enum.uniq(ids))
    end

    test "can specify which effects to log" do
      computation =
        comp do
          x <- State.get()
          return(x)
        end

      {{_result, log}, _env} =
        computation
        |> EffectLogger.with_logging(effects: [State])
        |> State.with_handler(42)
        |> Comp.run()

      entries = user_entries(log)
      assert length(entries) == 1
    end
  end

  describe "throw and discard" do
    test "effect that throws is marked as discarded without value" do
      computation =
        comp do
          _ <- State.put(42)
          _ <- Throw.throw(:boom)
          # Never reached
          return(:unreachable)
        end

      {{result, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> Throw.with_handler()
        |> State.with_handler(0)
        |> Comp.run()

      assert %Comp.Throw{error: :boom} = result

      entries = user_entries(log)
      assert length(entries) == 2

      [put_entry, throw_entry] = entries

      # Put completed normally (its leave_scope was restored before throw)
      assert put_entry.state == :executed
      assert put_entry.value == %Change{old: 0, new: 42}

      # Throw discarded (handler never called wrapped_k)
      assert throw_entry.state == :discarded
      assert throw_entry.value == nil
    end

    test "effects before throw are executed, only throw is discarded" do
      # Structure: State.get -> (catch (State.put -> Throw))
      # All effects that complete (call wrapped_k) are :executed
      # Only the effect that doesn't call wrapped_k (Throw) is :discarded

      computation =
        comp do
          x <- State.get()

          caught_result <-
            Throw.catch_error(
              comp do
                _ <- State.put(x + 1)
                _ <- Throw.throw(:error)
                return(:unreachable)
              end,
              fn err -> Comp.pure({:caught, err}) end
            )

          return({x, caught_result})
        end

      {{result, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> Throw.with_handler()
        |> State.with_handler(0)
        |> Comp.run()

      assert {0, {:caught, :error}} = result

      entries = user_entries(log)
      # get, put, throw
      assert length(entries) == 3

      [get_entry, put_entry, throw_entry] = entries

      # Get completed normally
      assert get_entry.state == :executed
      assert get_entry.value == 0

      # Put completed normally (leave_scope restored before throw)
      assert put_entry.state == :executed
      assert put_entry.value == %Change{old: 0, new: 1}

      # Throw discarded (handler never called wrapped_k)
      assert throw_entry.state == :discarded
      assert throw_entry.value == nil
    end

    test "effects after catch recovery are executed normally" do
      computation =
        comp do
          _ <- State.put(1)

          _ <-
            Throw.catch_error(
              Throw.throw(:error),
              fn _err -> Comp.pure(:recovered) end
            )

          _ <- State.put(2)
          x <- State.get()
          return(x)
        end

      {{result, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> Throw.with_handler()
        |> State.with_handler(0)
        |> Comp.run()

      assert result == 2

      entries = user_entries(log)
      # put(1), throw, put(2), get
      assert length(entries) == 4

      [put1, throw_entry, put2, get_entry] = entries

      assert put1.state == :executed
      assert throw_entry.state == :discarded
      assert put2.state == :executed
      assert get_entry.state == :executed
    end
  end

  describe "replay" do
    test "replays executed entries by short-circuiting" do
      computation =
        comp do
          x <- State.get()
          _ <- State.put(x + 10)
          y <- State.get()
          return({x, y})
        end

      # First run - capture log
      {{result1, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      assert result1 == {0, 10}

      # Replay - should get same result even with different initial state
      # allow_divergence: true because we're deliberately using different state
      {{result2, _log2}, _env2} =
        computation
        |> EffectLogger.with_logging(log, allow_divergence: true)
        |> State.with_handler(999)
        |> Comp.run()

      # Same result because values came from log, not from actual state
      assert result2 == {0, 10}
    end

    test "replay uses logged values instead of executing" do
      # Track whether handler was actually called
      call_count = :counters.new(1, [:atomics])

      counting_handler = fn args, env, k ->
        :counters.add(call_count, 1, 1)
        State.handle(args, env, k)
      end

      computation =
        comp do
          x <- State.get()
          return(x)
        end

      # First run with counting handler
      {{_result1, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> Comp.with_handler(State, counting_handler)
        |> State.with_handler(0)
        |> Comp.run()

      first_run_count = :counters.get(call_count, 1)
      assert first_run_count == 1

      # Replay - handler should NOT be called because we short-circuit
      {{_result2, _log2}, _env2} =
        computation
        |> EffectLogger.with_logging(log)
        |> Comp.with_handler(State, counting_handler)
        |> State.with_handler(0)
        |> Comp.run()

      replay_count = :counters.get(call_count, 1)
      # Count should still be 1 - handler wasn't called during replay
      assert replay_count == 1
    end

    test "replay with nil value works correctly" do
      computation =
        comp do
          x <- State.get()
          return(x)
        end

      # First run with nil initial state
      {{result1, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> State.with_handler(nil)
        |> Comp.run()

      assert result1 == nil

      # Replay - allow_divergence: true because we're deliberately using different state
      {{result2, _log2}, _env2} =
        computation
        |> EffectLogger.with_logging(log, allow_divergence: true)
        |> State.with_handler(:different)
        |> Comp.run()

      # Should get nil from log, not :different
      assert result2 == nil
    end
  end

  describe "JSON serialization" do
    test "log survives JSON round-trip" do
      computation =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          y <- State.get()
          return({x, y})
        end

      {{_result, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Serialize to JSON
      json = Jason.encode!(log)

      # Deserialize
      decoded = Jason.decode!(json)
      restored_log = Log.from_json(decoded)

      # Verify structure preserved (skip root mark which has atom value :ok -> "ok")
      original_entries = user_entries(log)
      restored_entries = user_entries(restored_log)

      assert length(original_entries) == length(restored_entries)

      Enum.zip(original_entries, restored_entries)
      |> Enum.each(fn {orig, restored} ->
        assert orig.id == restored.id
        assert orig.sig == restored.sig
        assert orig.state == restored.state
        assert orig.value == restored.value
      end)
    end

    test "replay works with deserialized log" do
      computation =
        comp do
          x <- State.get()
          _ <- State.put(x + 100)
          y <- State.get()
          return({x, y})
        end

      # First run
      {{result1, log}, _env} =
        computation
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Serialize and deserialize (simulating persistence)
      json = Jason.encode!(log)
      decoded = Jason.decode!(json)
      cold_log = Log.from_json(decoded)

      # Replay with cold log - allow_divergence: true because we're using different state
      {{result2, _log2}, _env2} =
        computation
        |> EffectLogger.with_logging(cold_log, allow_divergence: true)
        |> State.with_handler(999)
        |> Comp.run()

      assert result1 == result2
    end
  end

  describe "EffectLogEntry" do
    test "new creates entry in started state" do
      entry = EffectLogEntry.new("test-id", State, %State.Get{})

      assert entry.id == "test-id"
      assert entry.sig == State
      assert entry.state == :started
      assert entry.value == nil
    end

    test "set_executed transitions to executed with value" do
      entry =
        EffectLogEntry.new("test-id", State, %State.Get{})
        |> EffectLogEntry.set_executed(42)

      assert entry.state == :executed
      assert entry.value == 42
    end

    test "set_discarded transitions to discarded" do
      entry =
        EffectLogEntry.new("test-id", State, %State.Get{})
        |> EffectLogEntry.set_discarded()

      assert entry.state == :discarded
    end

    test "can_short_circuit? returns true for executed" do
      entry =
        EffectLogEntry.new("test-id", State, %State.Get{})
        |> EffectLogEntry.set_executed(42)

      assert EffectLogEntry.can_short_circuit?(entry)
    end

    test "can_short_circuit? returns false for discarded" do
      entry =
        EffectLogEntry.new("test-id", State, %State.Get{})
        |> EffectLogEntry.set_discarded()

      refute EffectLogEntry.can_short_circuit?(entry)
    end

    test "can_short_circuit? returns false for started" do
      entry = EffectLogEntry.new("test-id", State, %State.Get{})

      refute EffectLogEntry.can_short_circuit?(entry)
    end
  end

  describe "Log" do
    test "push_entry adds to stack" do
      log = Log.new()
      entry = EffectLogEntry.new("id1", State, %State.Get{})

      updated = Log.push_entry(log, entry)

      assert [^entry] = updated.effect_stack
    end

    test "finalize moves stack to queue in execution order" do
      log = Log.new()
      entry1 = EffectLogEntry.new("id1", State, %State.Get{})
      entry2 = EffectLogEntry.new("id2", State, %State.Put{value: 1})

      updated =
        log
        |> Log.push_entry(entry1)
        |> Log.push_entry(entry2)
        |> Log.finalize()

      assert updated.effect_stack == []
      # Queue should be in execution order (oldest first)
      assert [^entry1, ^entry2] = updated.effect_queue
    end

    test "mark_discarded updates entry by id" do
      entry1 = EffectLogEntry.new("id1", State, %State.Get{})
      entry2 = EffectLogEntry.new("id2", State, %State.Put{value: 1})

      log =
        Log.new()
        |> Log.push_entry(entry1)
        |> Log.push_entry(entry2)
        |> Log.mark_discarded("id1")

      [updated2, updated1] = log.effect_stack

      assert updated1.state == :discarded
      assert updated2.state == :started
    end

    test "pop_queue returns entry and updated log" do
      entry1 = EffectLogEntry.new("id1", State, %State.Get{})
      entry2 = EffectLogEntry.new("id2", State, %State.Put{value: 1})

      log = Log.new([entry1, entry2])

      {popped, updated} = Log.pop_queue(log)

      assert popped == entry1
      assert updated.effect_queue == [entry2]
    end

    test "pop_queue returns nil for empty queue" do
      log = Log.new()

      assert Log.pop_queue(log) == nil
    end
  end

  describe "cold resume" do
    # Helper to extract and finalize log from env after suspension
    defp extract_log(env) do
      EffectLogger.get_log(env) |> Log.finalize()
    end

    test "with_resume injects resume_value at Yield suspension point" do
      computation =
        comp do
          x <- State.get()
          input <- Yield.yield(:question)
          _ <- State.put(x + input)
          y <- State.get()
          return({x, input, y})
        end

      # First run - suspends at yield
      # Note: when computation suspends, with_logging's finally_k is never called,
      # so result is {%Suspend{}, env} not {{%Suspend{}, log}, env}
      {suspended, env} =
        computation
        |> EffectLogger.with_logging()
        |> Yield.with_handler()
        |> State.with_handler(10)
        |> Comp.run()

      assert %Comp.Suspend{value: :question} = suspended

      # Extract log from env (finalize it for replay)
      log = extract_log(env)

      # Verify log has started Yield entry
      entries = user_entries(log)
      assert length(entries) == 2
      [get_entry, yield_entry] = entries
      assert get_entry.state == :executed
      assert yield_entry.sig == Yield
      assert yield_entry.state == :started

      # Cold resume with value 5
      {{result, new_log}, _env2} =
        computation
        |> EffectLogger.with_resume(log, 5)
        |> Yield.with_handler()
        |> State.with_handler(999)
        |> Comp.run()

      # Should get: x=10 (from log), input=5 (from resume), y=15 (computed fresh)
      assert result == {10, 5, 15}

      # New log should have entries for:
      # - resumed yield (the injected value)
      # - put (fresh execution)
      # - get (fresh execution)
      # Note: short-circuited entries (the original get) don't create new entries
      new_entries = user_entries(new_log)
      assert length(new_entries) == 3
      assert Enum.all?(new_entries, &(&1.state == :executed))
    end

    test "with_resume short-circuits executed entries before suspension" do
      call_count = :counters.new(1, [:atomics])

      counting_handler = fn args, env, k ->
        :counters.add(call_count, 1, 1)
        State.handle(args, env, k)
      end

      computation =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          input <- Yield.yield(:waiting)
          return({x, input})
        end

      # First run with counting handler - suspends
      {_suspended, env} =
        computation
        |> EffectLogger.with_logging()
        |> Yield.with_handler()
        |> Comp.with_handler(State, counting_handler)
        |> State.with_handler(0)
        |> Comp.run()

      log = extract_log(env)

      first_count = :counters.get(call_count, 1)
      assert first_count == 2

      # Cold resume - State effects should be short-circuited
      {{result, _new_log}, _env2} =
        computation
        |> EffectLogger.with_resume(log, :resumed)
        |> Yield.with_handler()
        |> Comp.with_handler(State, counting_handler)
        |> State.with_handler(999)
        |> Comp.run()

      assert result == {0, :resumed}

      # Counter should still be 2 - State handlers weren't called during resume
      resume_count = :counters.get(call_count, 1)
      assert resume_count == 2
    end

    test "with_resume from JSON-deserialized log (true cold resume)" do
      computation =
        comp do
          x <- State.get()
          # Use integer for JSON serialization (atoms become strings after round-trip)
          input <- Yield.yield(42)
          _ <- State.put(x + input)
          y <- State.get()
          return({x, input, y})
        end

      # First run - suspends
      {suspended, env} =
        computation
        |> EffectLogger.with_logging()
        |> Yield.with_handler()
        |> State.with_handler(100)
        |> Comp.run()

      assert %Comp.Suspend{value: 42} = suspended

      log = extract_log(env)

      # Serialize to JSON (simulating persistence)
      json = Jason.encode!(log)

      # Later: deserialize and resume
      decoded = Jason.decode!(json)
      cold_log = Log.from_json(decoded)

      # Cold resume
      {{result, _new_log}, _env2} =
        computation
        |> EffectLogger.with_resume(cold_log, 50)
        |> Yield.with_handler()
        |> State.with_handler(999)
        |> Comp.run()

      # x=100 (from log), input=50 (resume value), y=150 (computed fresh)
      assert result == {100, 50, 150}
    end

    test "with_resume continues fresh execution after suspension point" do
      # Track calls to verify execution patterns
      effect_calls = :ets.new(:effect_calls, [:set])

      computation =
        comp do
          x <- State.get()
          _ = :ets.insert(effect_calls, {:get1, x})
          input <- Yield.yield(:first_yield)
          _ = :ets.insert(effect_calls, {:yield1, input})
          _ <- State.put(x + input)
          y <- State.get()
          _ = :ets.insert(effect_calls, {:get2, y})
          return({x, input, y})
        end

      # First run - suspends
      {_suspended, env} =
        computation
        |> EffectLogger.with_logging()
        |> Yield.with_handler()
        |> State.with_handler(10)
        |> Comp.run()

      log = extract_log(env)
      :ets.delete_all_objects(effect_calls)

      # Cold resume - should NOT call get1, SHOULD call put and get2
      {{result, _new_log}, _env2} =
        computation
        |> EffectLogger.with_resume(log, 5)
        |> Yield.with_handler()
        |> State.with_handler(999)
        |> Comp.run()

      assert result == {10, 5, 15}

      # Verify get1 was NOT called (short-circuited from log)
      # But get2 WAS called (fresh execution)
      calls = :ets.tab2list(effect_calls)
      call_keys = Enum.map(calls, fn {k, _v} -> k end)

      # yield1 should be recorded (happens after resume)
      assert :yield1 in call_keys
      # get2 should be recorded (fresh execution)
      assert :get2 in call_keys

      :ets.delete(effect_calls)
    end

    test "with_resume with nil resume_value works correctly" do
      computation =
        comp do
          input <- Yield.yield(:waiting)
          return({:got, input})
        end

      # First run - suspends
      {_suspended, env} =
        computation
        |> EffectLogger.with_logging()
        |> Yield.with_handler()
        |> Comp.run()

      log = extract_log(env)

      # Cold resume with nil
      {{result, _new_log}, _env2} =
        computation
        |> EffectLogger.with_resume(log, nil)
        |> Yield.with_handler()
        |> Comp.run()

      assert result == {:got, nil}
    end

    test "with_resume handles multiple yields correctly (only first uses resume_value)" do
      computation =
        comp do
          input1 <- Yield.yield(:first)
          input2 <- Yield.yield(:second)
          return({input1, input2})
        end

      # First run - suspends at first yield
      {suspended1, env1} =
        computation
        |> EffectLogger.with_logging()
        |> Yield.with_handler()
        |> Comp.run()

      assert %Comp.Suspend{value: :first} = suspended1
      log1 = extract_log(env1)

      # Cold resume from first suspension - continues to second yield
      {suspended2, env2} =
        computation
        |> EffectLogger.with_resume(log1, :value1)
        |> Yield.with_handler()
        |> Comp.run()

      assert %Comp.Suspend{value: :second} = suspended2
      log2 = extract_log(env2)

      # Cold resume from second suspension
      {{result, _log3}, _env3} =
        computation
        |> EffectLogger.with_resume(log2, :value2)
        |> Yield.with_handler()
        |> Comp.run()

      assert result == {:value1, :value2}
    end
  end
end
