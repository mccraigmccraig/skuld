defmodule Skuld.Effects.EffectLoggerTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.SerializableStruct
  alias Skuld.Effects.EffectLogger
  alias Skuld.Effects.EffectLogger.LogEntry
  alias Skuld.Effects.EffectLogger.LogEntry.Completed
  alias Skuld.Effects.EffectLogger.LogEntry.Finished
  alias Skuld.Effects.EffectLogger.LogEntry.Resumed
  alias Skuld.Effects.EffectLogger.LogEntry.Started
  alias Skuld.Effects.EffectLogger.LogEntry.Suspended
  alias Skuld.Effects.EffectLogger.LogEntry.Thrown
  alias Skuld.Effects.Reader
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield

  describe "logging simple effects" do
    test "logs State.get and State.put" do
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            Comp.bind(State.get(), fn y ->
              Comp.pure(y)
            end)
          end)
        end)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      assert result == 1
      assert length(log) == 3

      [get1, put1, get2] = log
      assert %Completed{effect: State, args: %State.Get{}, result: 0} = get1
      assert %Completed{effect: State, args: %State.Put{value: 1}, result: :ok} = put1
      assert %Completed{effect: State, args: %State.Get{}, result: 1} = get2
    end

    test "logs Reader.ask" do
      comp = Reader.asks(& &1.name)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> Reader.with_handler(%{name: "test"})
        |> Comp.run()

      assert result == "test"
      assert length(log) == 1

      [ask_entry] = log
      assert %Completed{effect: Reader, args: %Reader.Ask{}, result: %{name: "test"}} = ask_entry
    end

    test "logs multiple effects" do
      comp =
        Comp.bind(Reader.ask(), fn cfg ->
          Comp.bind(State.get(), fn s ->
            Comp.bind(State.put(s + 1), fn _ ->
              Comp.pure({cfg, s})
            end)
          end)
        end)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(10)
        |> Reader.with_handler(:config)
        |> Comp.run()

      assert result == {:config, 10}
      assert length(log) == 3

      effects = Enum.map(log, & &1.effect)
      assert effects == [Reader, State, State]
    end

    test "can filter which effects to log" do
      comp =
        Comp.bind(Reader.ask(), fn _ ->
          Comp.bind(State.get(), fn x ->
            Comp.pure(x)
          end)
        end)

      # Only log State, not Reader
      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging(effects: [State])
        |> State.with_handler(0)
        |> Reader.with_handler(:config)
        |> Comp.run()

      assert result == 0
      assert length(log) == 1
      assert hd(log).effect == State
    end
  end

  describe "logging control effects" do
    test "logs Throw" do
      comp = Throw.throw(:my_error)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> Throw.with_handler()
        |> Comp.run()

      assert %Comp.Throw{error: :my_error} = result
      assert length(log) == 1

      [throw_entry] = log

      assert %Thrown{
               effect: Throw,
               args: %Throw.ThrowOp{error: :my_error},
               error: :my_error
             } = throw_entry
    end

    test "logs effects before throw" do
      comp =
        Comp.bind(State.put(42), fn _ ->
          Comp.bind(State.get(), fn x ->
            Comp.bind(Throw.throw({:error, x}), fn _ ->
              # Never reached
              State.put(999)
            end)
          end)
        end)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      assert %Comp.Throw{error: {:error, 42}} = result
      assert length(log) == 3

      effects = Enum.map(log, & &1.effect)
      assert effects == [State, State, Throw]
    end
  end

  describe "replay simple effects" do
    test "replays State effects from log" do
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            Comp.bind(State.get(), fn y ->
              Comp.pure({x, y})
            end)
          end)
        end)

      # First run - capture log
      {{result1, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      assert result1 == {0, 1}

      # Replay - should get same result without real State operations
      # Use different initial state to prove replay works
      {result2, _env} =
        comp
        |> EffectLogger.replay(log)
        |> State.with_handler(999)
        |> Comp.run()

      # Result should match original, not the 999 initial state
      assert result2 == {0, 1}
    end

    test "replays Reader effects from log" do
      comp = Reader.asks(& &1.value)

      # First run - capture log
      {{result1, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> Reader.with_handler(%{value: 42})
        |> Comp.run()

      assert result1 == 42

      # Replay with different reader value
      {result2, _env} =
        comp
        |> EffectLogger.replay(log)
        |> Reader.with_handler(%{value: 999})
        |> Comp.run()

      # Should get original logged value
      assert result2 == 42
    end

    test "replay detects divergence" do
      comp1 =
        Comp.bind(State.get(), fn _ ->
          Comp.pure(:done)
        end)

      {{_result, log}, _env} =
        comp1
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Different computation that does State.put instead of State.get
      comp2 =
        Comp.bind(State.put(42), fn _ ->
          Comp.pure(:done)
        end)

      # Divergence raises RuntimeError which is converted to a Throw
      {result, _env} =
        comp2
        |> EffectLogger.replay(log)
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      assert %Comp.Throw{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: msg} = error.payload
      assert msg =~ "Replay divergence"
    end

    test "replay with :execute falls through on missing" do
      comp1 = State.get()

      {{_result, log}, _env} =
        comp1
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # Computation with extra effect not in log
      comp2 =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 100), fn _ ->
            State.get()
          end)
        end)

      # With :execute, extra effects run normally
      {result, _env} =
        comp2
        |> EffectLogger.replay(log, on_missing: :execute)
        |> State.with_handler(0)
        |> Comp.run()

      assert result == 100
    end
  end

  describe "logging and replay round-trip" do
    test "complex computation round-trips correctly" do
      comp =
        Comp.bind(Reader.ask(), fn %{multiplier: mult} ->
          Comp.bind(State.get(), fn x ->
            Comp.bind(State.put(x + 1), fn _ ->
              Comp.bind(State.get(), fn y ->
                Comp.bind(State.put(y * mult), fn _ ->
                  Comp.bind(State.get(), fn final ->
                    Comp.pure({x, y, final})
                  end)
                end)
              end)
            end)
          end)
        end)

      # Original run
      {{result1, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Reader.with_handler(%{multiplier: 10})
        |> Comp.run()

      assert result1 == {0, 1, 10}

      # Replay with completely different initial state
      {result2, _env} =
        comp
        |> EffectLogger.replay(log)
        |> State.with_handler(999)
        |> Reader.with_handler(%{multiplier: 1})
        |> Comp.run()

      assert result2 == {0, 1, 10}
    end
  end

  describe "log format" do
    test "log entries are Completed structs with expected fields" do
      comp = State.get()

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(42)
        |> Comp.run()

      assert %Completed{
               id: id,
               effect: State,
               args: %State.Get{},
               result: 42,
               timestamp: timestamp
             } = entry

      assert id != nil
      assert %DateTime{} = timestamp
    end

    test "custom timestamp function" do
      comp = State.get()
      fixed_time = ~U[2024-01-01 12:00:00Z]

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging(timestamp_fn: fn -> fixed_time end)
        |> State.with_handler(0)
        |> Comp.run()

      assert entry.timestamp == fixed_time
    end

    test "custom id function" do
      comp = State.get()

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging(id_fn: fn -> "custom-id" end)
        |> State.with_handler(0)
        |> Comp.run()

      assert entry.id == "custom-id"
    end

    test "default id is a UUID string" do
      comp = State.get()

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      # UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
      assert is_binary(entry.id)
      assert String.length(entry.id) == 36

      assert String.match?(
               entry.id,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
             )
    end
  end

  describe "JSON serialization" do
    test "Completed entry round-trips through JSON" do
      comp = State.get()

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(42)
        |> Comp.run()

      # Encode to JSON
      json = Jason.encode!(entry)
      assert is_binary(json)

      # Decode back
      decoded_map = Jason.decode!(json)
      decoded = SerializableStruct.decode(decoded_map)

      assert %Completed{} = decoded
      assert decoded.id == entry.id
      assert decoded.effect == entry.effect
      assert decoded.result == entry.result
      assert DateTime.compare(decoded.timestamp, entry.timestamp) == :eq
    end

    test "Thrown entry round-trips through JSON" do
      comp = Throw.throw(:my_error)

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> Throw.with_handler()
        |> Comp.run()

      assert %Thrown{} = entry

      # Encode to JSON
      json = Jason.encode!(entry)

      # Decode back
      decoded_map = Jason.decode!(json)
      decoded = SerializableStruct.decode(decoded_map)

      assert %Thrown{} = decoded
      assert decoded.id == entry.id
      assert decoded.effect == entry.effect
      assert decoded.error == Atom.to_string(entry.error)
      assert DateTime.compare(decoded.timestamp, entry.timestamp) == :eq
    end

    test "full log round-trips through JSON" do
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            Comp.bind(State.get(), fn y ->
              Comp.pure(y)
            end)
          end)
        end)

      {{_result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      assert length(log) == 3

      # Encode entire log to JSON
      json = Jason.encode!(log)

      # Decode back
      decoded_maps = Jason.decode!(json)
      decoded_log = LogEntry.decode_log(decoded_maps)

      assert length(decoded_log) == 3

      Enum.zip(log, decoded_log)
      |> Enum.each(fn {original, decoded} ->
        assert original.id == decoded.id
        assert original.effect == decoded.effect
        assert DateTime.compare(original.timestamp, decoded.timestamp) == :eq
      end)
    end

    test "log with different entry types round-trips" do
      comp =
        Comp.bind(State.put(42), fn _ ->
          Throw.throw(:error_after_state)
        end)

      {{_result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      # Should have Completed for State.put and Thrown for Throw
      assert length(log) == 2

      json = Jason.encode!(log)
      decoded_maps = Jason.decode!(json)
      decoded_log = LogEntry.decode_log(decoded_maps)

      [decoded_completed, decoded_thrown] = decoded_log
      assert %Completed{effect: State} = decoded_completed
      assert %Thrown{effect: Throw} = decoded_thrown
    end

    test "args are properly serialized and deserialized" do
      comp = State.put(123)

      {{_result, [entry]}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run()

      json = Jason.encode!(entry)
      decoded_map = Jason.decode!(json)
      decoded = SerializableStruct.decode(decoded_map)

      # Args should be decoded back to the original struct type
      assert %State.Put{value: 123} = decoded.args
    end

    test "json_encode_log/2 encodes log entries to JSON string" do
      comp = Comp.bind(State.get(), fn _x -> Comp.pure(:done) end)

      {{:done, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(42)
        |> Comp.run()

      json = LogEntry.json_encode_log(log)
      assert is_binary(json)
      assert String.contains?(json, "Completed")
      assert String.contains?(json, "State.Get")
    end

    test "json_encode_log/2 with pretty option formats output" do
      comp = State.get()

      {{_result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(42)
        |> Comp.run()

      compact = LogEntry.json_encode_log(log)
      pretty = LogEntry.json_encode_log(log, pretty: true)

      # Pretty output should have newlines
      refute String.contains?(compact, "\n")
      assert String.contains?(pretty, "\n")
    end

    test "json_decode_log/1 decodes JSON string to log entries" do
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            Comp.pure(x)
          end)
        end)

      {{42, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(42)
        |> Comp.run()

      json = LogEntry.json_encode_log(log)
      assert {:ok, decoded_log} = LogEntry.json_decode_log(json)

      assert length(decoded_log) == 2
      assert [%Completed{}, %Completed{}] = decoded_log
    end

    test "json_decode_log/1 returns error for invalid JSON" do
      assert {:error, %Jason.DecodeError{}} = LogEntry.json_decode_log("not valid json")
    end

    test "json_decode_log/1 returns error for non-list JSON" do
      json = Jason.encode!(%{foo: "bar"})
      assert {:error, :not_a_list} = LogEntry.json_decode_log(json)
    end

    test "json_encode_log and json_decode_log round-trip correctly" do
      comp =
        Comp.bind(Reader.ask(), fn x ->
          Comp.bind(State.put(x * 2), fn _ ->
            Comp.bind(State.get(), fn y ->
              Comp.pure(y)
            end)
          end)
        end)

      {{20, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> Reader.with_handler(10)
        |> State.with_handler(0)
        |> Comp.run()

      json = LogEntry.json_encode_log(log)
      {:ok, decoded_log} = LogEntry.json_decode_log(json)

      assert length(decoded_log) == length(log)

      Enum.zip(log, decoded_log)
      |> Enum.each(fn {original, decoded} ->
        assert original.id == decoded.id
        assert original.effect == decoded.effect
        # Note: atoms in result become strings after JSON round-trip
        # (e.g., :ok -> "ok"), but other values preserve correctly
      end)

      # Check specific results - integers should round-trip exactly
      [reader_entry, state_put_entry, state_get_entry] = decoded_log
      assert reader_entry.result == 10
      # :ok -> "ok" in JSON
      assert state_put_entry.result == "ok"
      assert state_get_entry.result == 20
    end
  end

  # ============================================================
  # Yield (Suspend/Resume) Logging Tests
  # ============================================================

  describe "logging Yield effects" do
    test "single yield logs Started, Suspended, Resumed, Finished" do
      comp =
        Comp.bind(Yield.yield(:my_value), fn input ->
          Comp.pure({:got, input})
        end)
        |> EffectLogger.with_logging()
        |> Yield.with_handler()

      # Run until suspension
      {%Comp.Suspend{value: :my_value, resume: resume}, _env} = Comp.run(comp)

      # Resume with a value
      {{result, log}, _env} = resume.(:resumed_input)

      assert result == {:got, :resumed_input}

      # Should have 4 log entries: Started, Suspended, Resumed, Finished
      assert length(log) == 4

      [started, suspended, resumed, finished] = log

      assert %Started{effect: Yield, args: %Yield.YieldOp{value: :my_value}} = started
      assert %Suspended{yielded: :my_value} = suspended
      assert %Resumed{input: :resumed_input} = resumed
      assert %Finished{result: {:got, :resumed_input}} = finished

      # All entries should share the same ID
      assert started.id == suspended.id
      assert started.id == resumed.id
      assert started.id == finished.id
    end

    test "multiple yields log complete lifecycle for each" do
      comp =
        Comp.bind(Yield.yield(:first), fn a ->
          Comp.bind(Yield.yield(:second), fn b ->
            Comp.pure({a, b})
          end)
        end)
        |> EffectLogger.with_logging()
        |> Yield.with_handler()

      # First yield
      {%Comp.Suspend{value: :first, resume: r1}, _} = Comp.run(comp)

      # Resume first, get second yield
      {%Comp.Suspend{value: :second, resume: r2}, _} = r1.(:input_a)

      # Resume second, get final result
      {{result, log}, _} = r2.(:input_b)

      assert result == {:input_a, :input_b}

      # Should have 8 entries: 4 for each yield
      assert length(log) == 8

      # Group by ID
      ids = log |> Enum.map(& &1.id) |> Enum.uniq()
      assert length(ids) == 2

      [first_id, second_id] = ids

      first_entries = Enum.filter(log, &(&1.id == first_id))
      second_entries = Enum.filter(log, &(&1.id == second_id))

      # Each yield should have Started, Suspended, Resumed, Finished
      assert [%Started{}, %Suspended{}, %Resumed{}, %Finished{}] = first_entries
      assert [%Started{}, %Suspended{}, %Resumed{}, %Finished{}] = second_entries
    end

    test "yield with state logs both effect types correctly" do
      comp =
        Comp.bind(State.get(), fn before ->
          Comp.bind(Yield.yield({:at, before}), fn input ->
            Comp.bind(State.put(input), fn _ ->
              Comp.bind(State.get(), fn after_val ->
                Comp.pure({before, after_val})
              end)
            end)
          end)
        end)
        |> EffectLogger.with_logging()
        |> State.with_handler(42)
        |> Yield.with_handler()

      {%Comp.Suspend{resume: resume}, _} = Comp.run(comp)
      {{result, log}, _} = resume.(100)

      assert result == {42, 100}

      # Should have: State.get, Started, Suspended, Resumed, State.put, State.get, Finished
      assert length(log) == 7

      effects =
        Enum.map(log, fn
          %Completed{effect: e} -> {:completed, e}
          %Started{effect: e} -> {:started, e}
          %Suspended{} -> :suspended
          %Resumed{} -> :resumed
          %Finished{} -> :finished
        end)

      assert effects == [
               {:completed, State},
               {:started, Yield},
               :suspended,
               :resumed,
               {:completed, State},
               {:completed, State},
               :finished
             ]
    end

    test "yield IDs are unique UUIDs" do
      comp =
        Comp.bind(Yield.yield(:a), fn _ ->
          Comp.bind(Yield.yield(:b), fn _ ->
            Comp.pure(:done)
          end)
        end)
        |> EffectLogger.with_logging()
        |> Yield.with_handler()

      {%Comp.Suspend{resume: r1}, _} = Comp.run(comp)
      {%Comp.Suspend{resume: r2}, _} = r1.(:ok)
      {{:done, log}, _} = r2.(:ok)

      ids = log |> Enum.map(& &1.id) |> Enum.uniq()
      assert length(ids) == 2

      # Both should be valid UUID strings
      Enum.each(ids, fn id ->
        assert is_binary(id)
        assert String.length(id) == 36

        assert String.match?(
                 id,
                 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
               )
      end)
    end

    test "timestamps are recorded for each lifecycle event" do
      fixed_times = [
        ~U[2024-01-01 10:00:00Z],
        ~U[2024-01-01 10:00:01Z],
        ~U[2024-01-01 10:00:02Z],
        ~U[2024-01-01 10:00:03Z]
      ]

      time_agent = Agent.start_link(fn -> fixed_times end) |> elem(1)

      timestamp_fn = fn ->
        Agent.get_and_update(time_agent, fn
          [h | t] -> {h, t}
          [] -> {DateTime.utc_now(), []}
        end)
      end

      comp =
        Comp.bind(Yield.yield(:value), fn _ ->
          Comp.pure(:done)
        end)
        |> EffectLogger.with_logging(timestamp_fn: timestamp_fn)
        |> Yield.with_handler()

      {%Comp.Suspend{resume: resume}, _} = Comp.run(comp)
      {{:done, log}, _} = resume.(:ok)

      [started, suspended, resumed, finished] = log

      assert started.timestamp == ~U[2024-01-01 10:00:00Z]
      assert suspended.timestamp == ~U[2024-01-01 10:00:01Z]
      assert resumed.timestamp == ~U[2024-01-01 10:00:02Z]
      assert finished.timestamp == ~U[2024-01-01 10:00:03Z]

      Agent.stop(time_agent)
    end

    test "yield that throws logs Started, Suspended, Resumed but not Finished" do
      comp =
        Comp.bind(Yield.yield(:value), fn _ ->
          Throw.throw(:error_after_resume)
        end)
        |> EffectLogger.with_logging()
        |> Throw.with_handler()
        |> Yield.with_handler()

      {%Comp.Suspend{resume: resume}, _} = Comp.run(comp)
      {{%Comp.Throw{error: :error_after_resume}, log}, _} = resume.(:ok)

      # Should have: Started, Suspended, Resumed, Thrown (for the Throw effect)
      # Note: Finished is NOT logged because the computation threw
      assert length(log) == 4

      types =
        Enum.map(log, fn
          %Started{} -> :started
          %Suspended{} -> :suspended
          %Resumed{} -> :resumed
          %Thrown{} -> :thrown
          %Finished{} -> :finished
        end)

      assert types == [:started, :suspended, :resumed, :thrown]
    end
  end

  # ============================================================
  # Retry from Failure Tests
  # ============================================================

  describe "retry_from_failure/3" do
    test "retries computation after throw, replaying effects before failure" do
      # Computation that does some state ops then throws
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 10), fn _ ->
            Comp.bind(State.get(), fn y ->
              Throw.throw({:failed_at, y})
            end)
          end)
        end)

      # First run - capture log with failure
      {{%Comp.Throw{error: {:failed_at, 10}}, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      # Log should have: State.get, State.put, State.get, Thrown
      assert length(log) == 4
      assert %Thrown{} = List.last(log)

      # Now create a "fixed" computation that doesn't throw
      fixed_comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 10), fn _ ->
            Comp.bind(State.get(), fn y ->
              Comp.pure({:success, y})
            end)
          end)
        end)

      # Retry from failure - use different initial state to prove replay works
      {result, _env} =
        fixed_comp
        |> EffectLogger.retry_from_failure(log)
        |> State.with_handler(999)
        |> Throw.with_handler()
        |> Comp.run()

      # Should get original values (0, 10) from replay, not 999
      assert result == {:success, 10}
    end

    test "retries with empty effects before failure still works" do
      # Computation that throws immediately
      comp = Throw.throw(:immediate_error)

      {{%Comp.Throw{error: :immediate_error}, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> Throw.with_handler()
        |> Comp.run()

      # Log should only have the Thrown entry
      assert length(log) == 1
      assert %Thrown{} = hd(log)

      # Fixed computation
      fixed_comp = Comp.pure(:fixed)

      # Retry - no effects to replay, just runs the new computation
      {result, _env} =
        fixed_comp
        |> EffectLogger.retry_from_failure(log)
        |> Throw.with_handler()
        |> Comp.run()

      assert result == :fixed
    end

    test "retries with Reader and State effects" do
      comp =
        Comp.bind(Reader.ask(), fn cfg ->
          Comp.bind(State.get(), fn x ->
            Comp.bind(State.put(x + cfg.increment), fn _ ->
              Throw.throw(:config_error)
            end)
          end)
        end)

      {{%Comp.Throw{}, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(100)
        |> Reader.with_handler(%{increment: 50})
        |> Throw.with_handler()
        |> Comp.run()

      # Log: Reader.ask, State.get, State.put, Thrown
      assert length(log) == 4

      # Fixed computation - note: effects before throw are replayed,
      # and we return values from those replayed effects
      fixed_comp =
        Comp.bind(Reader.ask(), fn cfg ->
          Comp.bind(State.get(), fn x ->
            Comp.bind(State.put(x + cfg.increment), fn _ ->
              # Return the replayed values (x was 100, cfg.increment was 50)
              Comp.pure({:ok, cfg, x})
            end)
          end)
        end)

      # Retry with completely different config/state to prove replay works
      {result, _env} =
        fixed_comp
        |> EffectLogger.retry_from_failure(log)
        |> State.with_handler(999)
        |> Reader.with_handler(%{increment: 1})
        |> Throw.with_handler()
        |> Comp.run()

      # Should get original values from replay: cfg = %{increment: 50}, x = 100
      assert result == {:ok, %{increment: 50}, 100}
    end

    test "cold log retry - JSON round-trip" do
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x * 2), fn _ ->
            Comp.bind(State.get(), fn _y ->
              # Use atom for error - atoms are JSON-serializable as strings
              Throw.throw(:doubled_error)
            end)
          end)
        end)

      {{%Comp.Throw{}, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(5)
        |> Throw.with_handler()
        |> Comp.run()

      # Serialize to JSON and back (simulating persistence)
      json = LogEntry.json_encode_log(log)
      {:ok, cold_log} = LogEntry.json_decode_log(json)

      # Fixed computation - returns the value from replayed State.get (x = 5)
      fixed_comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x * 2), fn _ ->
            # Return the original x value from replay
            Comp.pure(x)
          end)
        end)

      # Retry from cold log
      {result, _env} =
        fixed_comp
        |> EffectLogger.retry_from_failure(cold_log)
        |> State.with_handler(999)
        |> Throw.with_handler()
        |> Comp.run()

      # Original x was 5 (from replayed State.get)
      assert result == 5
    end

    test "verifies effects before failure are replayed not re-executed" do
      # Original computation that fails after 2 State ops
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            Throw.throw(:after_state_ops)
          end)
        end)

      # Run with initial state 0
      {{%Comp.Throw{}, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Throw.with_handler()
        |> Comp.run()

      # Verify log contains the right entries
      assert length(log) == 3
      assert [%Completed{effect: State, result: 0}, %Completed{effect: State}, %Thrown{}] = log

      # Fixed computation with an extra State.get not in the log
      fixed_comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            # This State.get is NOT in the log, so it should execute fresh
            Comp.bind(State.get(), fn y ->
              Comp.pure({x, y})
            end)
          end)
        end)

      # Retry with different initial state (999) to prove replay works
      # - State.get -> replayed, returns 0 (from log)
      # - State.put(1) -> replayed, returns :ok (from log), but doesn't actually mutate state
      # - State.get -> NOT in log, executes fresh, reads actual state (999)
      {result, _env} =
        fixed_comp
        |> EffectLogger.retry_from_failure(log)
        |> State.with_handler(999)
        |> Throw.with_handler()
        |> Comp.run()

      # x = 0 (replayed from log), y = 999 (fresh execution with initial state)
      # This proves:
      # 1. Replayed effects return logged values (x = 0, not 999)
      # 2. New effects execute fresh (y = 999, reading actual state)
      assert result == {0, 999}
    end

    test "handles log with no Thrown entry gracefully" do
      # Capture a successful log (no Thrown entry)
      comp =
        Comp.bind(State.get(), fn x ->
          Comp.pure(x + 1)
        end)

      {{result, log}, _env} =
        comp
        |> EffectLogger.with_logging()
        |> State.with_handler(10)
        |> Comp.run()

      assert result == 11
      assert length(log) == 1
      assert %Completed{} = hd(log)

      # retry_from_failure with no Thrown entry replays the whole log
      {retry_result, _env} =
        comp
        |> EffectLogger.retry_from_failure(log)
        |> State.with_handler(999)
        |> Comp.run()

      # Should still get the replayed value
      assert retry_result == 11
    end
  end
end
