defmodule Skuld.Effects.WriterTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.Writer
  alias Skuld.Effects.Yield
  alias Skuld.Effects.Throw

  # ============================================================
  # Default Tag Tests
  # ============================================================

  describe "tell with default tag" do
    test "appends message to log" do
      comp =
        Comp.bind(Writer.tell("msg1"), fn _ ->
          Comp.bind(Writer.tell("msg2"), fn _ ->
            Writer.peek()
          end)
        end)
        |> Writer.with_handler()

      {result, _env} = Comp.run(comp)
      assert ["msg2", "msg1"] = result
    end
  end

  describe "peek with default tag" do
    test "reads current log" do
      comp =
        Comp.bind(Writer.tell("first"), fn _ ->
          Comp.bind(Writer.tell("second"), fn _ ->
            Writer.peek()
          end)
        end)
        |> Writer.with_handler()

      {result, _env} = Comp.run(comp)
      assert ["second", "first"] = result
    end
  end

  describe "with_handler output (default tag)" do
    test "includes final log in result" do
      comp =
        Comp.bind(Writer.tell("step 1"), fn _ ->
          Comp.bind(Writer.tell("step 2"), fn _ ->
            Comp.pure(:done)
          end)
        end)
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)

      {result, _env} = Comp.run(comp)

      assert {:done, ["step 2", "step 1"]} = result
    end

    test "with custom transformation" do
      comp =
        Comp.bind(Writer.tell("a"), fn _ ->
          Comp.bind(Writer.tell("b"), fn _ ->
            Comp.bind(Writer.tell("c"), fn _ ->
              Comp.pure(42)
            end)
          end)
        end)
        |> Writer.with_handler([],
          output: fn result, log -> %{value: result, log_count: length(log)} end
        )

      {result, _env} = Comp.run(comp)

      assert %{value: 42, log_count: 3} = result
    end

    test "with initial log entries" do
      comp =
        Comp.bind(Writer.tell("new"), fn _ ->
          Comp.pure(:ok)
        end)
        |> Writer.with_handler(["existing"],
          output: fn result, log -> {result, log} end
        )

      {result, _env} = Comp.run(comp)

      assert {:ok, ["new", "existing"]} = result
    end
  end

  describe "tell_many with default tag" do
    test "tells multiple messages" do
      comp =
        Comp.bind(Writer.tell_many(["a", "b", "c"]), fn _ ->
          Writer.peek()
        end)
        |> Writer.with_handler()

      {result, _env} = Comp.run(comp)
      assert ["c", "b", "a"] = result
    end
  end

  describe "clear with default tag" do
    test "clears log" do
      comp =
        Comp.bind(Writer.tell("msg1"), fn _ ->
          Comp.bind(Writer.clear(), fn _ ->
            Comp.bind(Writer.tell("msg2"), fn _ ->
              Writer.peek()
            end)
          end)
        end)
        |> Writer.with_handler()

      {result, _env} = Comp.run(comp)
      assert ["msg2"] = result
    end
  end

  # ============================================================
  # Explicit Tag Tests
  # ============================================================

  describe "tell with explicit tag" do
    test "appends message to log for tag" do
      comp =
        Comp.bind(Writer.tell(:audit, "msg1"), fn _ ->
          Comp.bind(Writer.tell(:audit, "msg2"), fn _ ->
            Writer.peek(:audit)
          end)
        end)
        |> Writer.with_handler([], tag: :audit)

      {result, _env} = Comp.run(comp)
      # Logs are in reverse chronological order
      assert ["msg2", "msg1"] = result
    end

    test "multiple tags accumulate independently" do
      comp =
        Comp.bind(Writer.tell(:audit, "audit1"), fn _ ->
          Comp.bind(Writer.tell(:metrics, "metric1"), fn _ ->
            Comp.bind(Writer.tell(:audit, "audit2"), fn _ ->
              Comp.bind(Writer.tell(:metrics, "metric2"), fn _ ->
                Comp.bind(Writer.peek(:audit), fn audit_log ->
                  Comp.bind(Writer.peek(:metrics), fn metrics_log ->
                    Comp.pure({audit_log, metrics_log})
                  end)
                end)
              end)
            end)
          end)
        end)
        |> Writer.with_handler([], tag: :audit)
        |> Writer.with_handler([], tag: :metrics)

      {{audit_log, metrics_log}, _env} = Comp.run(comp)
      assert ["audit2", "audit1"] = audit_log
      assert ["metric2", "metric1"] = metrics_log
    end
  end

  describe "peek with explicit tag" do
    test "reads current log for tag" do
      comp =
        Comp.bind(Writer.tell(:log, "first"), fn _ ->
          Comp.bind(Writer.tell(:log, "second"), fn _ ->
            Writer.peek(:log)
          end)
        end)
        |> Writer.with_handler([], tag: :log)

      {result, _env} = Comp.run(comp)
      assert ["second", "first"] = result
    end
  end

  describe "listen with explicit tag" do
    test "captures log output for tag during computation" do
      comp =
        Comp.bind(Writer.tell(:log, "before"), fn _ ->
          inner =
            Writer.listen(
              :log,
              Comp.bind(Writer.tell(:log, "inner1"), fn _ ->
                Comp.bind(Writer.tell(:log, "inner2"), fn _ ->
                  Comp.pure(:result)
                end)
              end)
            )

          Comp.bind(inner, fn {result, captured} ->
            Comp.bind(Writer.tell(:log, "after"), fn _ ->
              Comp.bind(Writer.peek(:log), fn full_log ->
                Comp.pure({result, captured, full_log})
              end)
            end)
          end)
        end)
        |> Writer.with_handler([], tag: :log)

      {{:result, captured, full_log}, _env} = Comp.run(comp)
      assert ["inner2", "inner1"] = captured
      # Full log includes all messages
      assert ["after", "inner2", "inner1", "before"] = full_log
    end

    test "listen on one tag does not capture other tags" do
      comp =
        Comp.bind(
          Writer.listen(
            :a,
            Comp.bind(Writer.tell(:a, "a-msg"), fn _ ->
              Comp.bind(Writer.tell(:b, "b-msg"), fn _ ->
                Comp.pure(:ok)
              end)
            end)
          ),
          fn {result, captured_a} ->
            Comp.bind(Writer.peek(:b), fn b_log ->
              Comp.pure({result, captured_a, b_log})
            end)
          end
        )
        |> Writer.with_handler([], tag: :a)
        |> Writer.with_handler([], tag: :b)

      {{:ok, captured_a, b_log}, _env} = Comp.run(comp)
      assert ["a-msg"] = captured_a
      assert ["b-msg"] = b_log
    end
  end

  describe "censor with explicit tag" do
    test "transforms logs for tag during computation" do
      comp =
        Comp.bind(
          Writer.censor(
            :log,
            Comp.bind(Writer.tell(:log, "secret"), fn _ ->
              Comp.pure(:done)
            end),
            fn logs -> Enum.map(logs, fn _ -> "[REDACTED]" end) end
          ),
          fn result ->
            Comp.bind(Writer.peek(:log), fn log ->
              Comp.pure({result, log})
            end)
          end
        )
        |> Writer.with_handler([], tag: :log)

      {{:done, log}, _env} = Comp.run(comp)
      assert ["[REDACTED]"] = log
    end
  end

  describe "with_handler explicit tag" do
    test "installs handler and initializes log for tag" do
      comp =
        Comp.bind(Writer.tell(:log, "msg"), fn _ ->
          Writer.peek(:log)
        end)
        |> Writer.with_handler([], tag: :log)

      {result, _env} = Comp.run(comp)
      assert ["msg"] = result
    end

    test "with initial log entries" do
      comp =
        Comp.bind(Writer.tell(:log, "new"), fn _ ->
          Writer.peek(:log)
        end)
        |> Writer.with_handler(["existing"], tag: :log)

      {result, _env} = Comp.run(comp)
      assert ["new", "existing"] = result
    end

    test "shadows outer handler of same tag and restores it" do
      comp =
        Comp.bind(Writer.tell(:log, "outer1"), fn _ ->
          inner =
            Comp.bind(Writer.tell(:log, "inner1"), fn _ ->
              Writer.peek(:log)
            end)
            |> Writer.with_handler([], tag: :log)

          Comp.bind(inner, fn inner_log ->
            Comp.bind(Writer.tell(:log, "outer2"), fn _ ->
              Comp.bind(Writer.peek(:log), fn outer_log ->
                Comp.pure({inner_log, outer_log})
              end)
            end)
          end)
        end)
        |> Writer.with_handler([], tag: :log)

      {{inner_log, outer_log}, _env} = Comp.run(comp)
      assert ["inner1"] = inner_log
      assert ["outer2", "outer1"] = outer_log
    end

    test "cleanup on throw" do
      comp =
        Throw.catch_error(
          Comp.bind(
            Comp.bind(Writer.tell(:log, "inner"), fn _ ->
              Throw.throw(:error)
            end)
            |> Writer.with_handler([], tag: :log),
            fn _ -> Comp.pure(:unreachable) end
          ),
          fn _error ->
            Comp.bind(Writer.tell(:log, "after_catch"), fn _ ->
              Writer.peek(:log)
            end)
          end
        )
        |> Writer.with_handler([], tag: :log)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      # Outer log preserved, inner log discarded
      assert ["after_catch"] = result
    end

    test "with_handler output includes final log" do
      comp =
        Comp.bind(Writer.tell(:audit, "step 1"), fn _ ->
          Comp.bind(Writer.tell(:audit, "step 2"), fn _ ->
            Comp.pure(:done)
          end)
        end)
        |> Writer.with_handler([], tag: :audit, output: fn result, log -> {result, log} end)

      {result, _env} = Comp.run(comp)

      assert {:done, ["step 2", "step 1"]} = result
    end
  end

  describe "tell_many with explicit tag" do
    test "tells multiple messages" do
      comp =
        Comp.bind(Writer.tell_many(:log, ["a", "b", "c"]), fn _ ->
          Writer.peek(:log)
        end)
        |> Writer.with_handler([], tag: :log)

      {result, _env} = Comp.run(comp)
      assert ["c", "b", "a"] = result
    end
  end

  describe "clear with explicit tag" do
    test "clears log for tag" do
      comp =
        Comp.bind(Writer.tell(:log, "msg1"), fn _ ->
          Comp.bind(Writer.clear(:log), fn _ ->
            Comp.bind(Writer.tell(:log, "msg2"), fn _ ->
              Writer.peek(:log)
            end)
          end)
        end)
        |> Writer.with_handler([], tag: :log)

      {result, _env} = Comp.run(comp)
      assert ["msg2"] = result
    end
  end

  describe "get_log" do
    test "extracts log with default tag" do
      comp =
        Comp.bind(Writer.tell("msg"), fn _ ->
          Comp.pure(:done)
        end)
        |> Writer.with_handler()

      {_result, env} = Comp.run(comp)
      # Log is removed after handler scope exits
      assert Writer.get_log(env) == []
    end

    test "extracts log with explicit tag" do
      comp =
        Comp.bind(Writer.tell(:audit, "msg"), fn _ ->
          Comp.pure(:done)
        end)
        |> Writer.with_handler([], tag: :audit)

      {_result, env} = Comp.run(comp)
      # Log is removed after handler scope exits
      assert Writer.get_log(env, :audit) == []
    end
  end

  describe "mixing default and explicit tags" do
    test "default and explicit tags are independent" do
      comp =
        Comp.bind(Writer.tell(:tagged, "tagged_msg"), fn _ ->
          Comp.bind(Writer.tell("untagged_msg"), fn _ ->
            Comp.bind(Writer.peek(:tagged), fn tagged_log ->
              Comp.bind(Writer.peek(), fn untagged_log ->
                Comp.pure({tagged_log, untagged_log})
              end)
            end)
          end)
        end)
        |> Writer.with_handler([], tag: :tagged)
        |> Writer.with_handler()

      {{tagged_log, untagged_log}, _env} = Comp.run(comp)
      assert ["tagged_msg"] = tagged_log
      assert ["untagged_msg"] = untagged_log
    end
  end

  # ============================================================
  # Control Effect Tests - Yield (Suspend/Resume)
  # ============================================================

  describe "listen + Yield" do
    test "listen captures logs before and after suspension" do
      comp =
        Writer.listen(
          Comp.bind(Writer.tell("before yield"), fn _ ->
            Comp.bind(Yield.yield(:pause), fn _ ->
              Comp.bind(Writer.tell("after yield"), fn _ ->
                Comp.pure(:done)
              end)
            end)
          end)
        )
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Yield.with_handler()

      # First run - should suspend
      {%Comp.ExternalSuspend{value: :pause, resume: resume}, _env} = Comp.run(comp)

      # Resume - should complete and capture all logs
      {result, _env} = resume.(:resumed)

      # listen returns {inner_result, captured_logs}
      # outer result is {{inner_result, captured}, full_log}
      assert {{:done, captured}, full_log} = result
      assert captured == ["after yield", "before yield"]
      assert full_log == ["after yield", "before yield"]
    end

    test "listen with multiple yields captures correctly" do
      comp =
        Writer.listen(
          Comp.bind(Writer.tell("a"), fn _ ->
            Comp.bind(Yield.yield(:first), fn input1 ->
              Comp.bind(Writer.tell(input1), fn _ ->
                Comp.bind(Yield.yield(:second), fn input2 ->
                  Comp.bind(Writer.tell(input2), fn _ ->
                    Comp.pure(:done)
                  end)
                end)
              end)
            end)
          end)
        )
        |> Writer.with_handler([], output: fn result, _log -> result end)
        |> Yield.with_handler()

      {%Comp.ExternalSuspend{resume: r1}, _} = Comp.run(comp)
      {%Comp.ExternalSuspend{resume: r2}, _} = r1.("b")
      {result, _} = r2.("c")

      assert {:done, ["c", "b", "a"]} = result
    end

    test "listen preserves logs from before listen scope" do
      comp =
        Comp.bind(Writer.tell("outer"), fn _ ->
          Writer.listen(
            Comp.bind(Writer.tell("inner"), fn _ ->
              Comp.bind(Yield.yield(:pause), fn _ ->
                Comp.pure(:result)
              end)
            end)
          )
        end)
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Yield.with_handler()

      {%Comp.ExternalSuspend{resume: resume}, _} = Comp.run(comp)
      {result, _} = resume.(:ok)

      # listen only captures "inner", full log has both
      assert {{:result, ["inner"]}, ["inner", "outer"]} = result
    end
  end

  describe "listen + Throw" do
    test "listen propagates throw from inner computation" do
      comp =
        Writer.listen(
          Comp.bind(Writer.tell("before throw"), fn _ ->
            Comp.bind(Throw.throw(:my_error), fn _ ->
              Comp.bind(Writer.tell("never reached"), fn _ ->
                Comp.pure(:done)
              end)
            end)
          end)
        )
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      # Should get Throw sentinel, not the listen result
      assert {%Comp.Throw{error: :my_error}, _log} = result
    end

    test "listen logs captured before throw are preserved" do
      comp =
        Throw.catch_error(
          Writer.listen(
            Comp.bind(Writer.tell("before"), fn _ ->
              Throw.throw(:error)
            end)
          ),
          fn _err ->
            Comp.bind(Writer.peek(), fn log ->
              Comp.pure({:caught, log})
            end)
          end
        )
        |> Writer.with_handler([], output: fn result, _log -> result end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      # Logs written before throw should be preserved
      assert {:caught, ["before"]} = result
    end
  end

  # ============================================================
  # pass + Control Effects
  # ============================================================

  describe "pass + Yield" do
    test "pass applies transform after resume" do
      comp =
        Writer.pass(
          Comp.bind(Writer.tell("a"), fn _ ->
            Comp.bind(Yield.yield(:pause), fn _ ->
              Comp.bind(Writer.tell("b"), fn _ ->
                Comp.pure({:done, fn logs -> Enum.map(logs, &String.upcase/1) end})
              end)
            end)
          end)
        )
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Yield.with_handler()

      {%Comp.ExternalSuspend{resume: resume}, _} = Comp.run(comp)
      {result, _} = resume.(:ok)

      # Transform should uppercase the captured logs
      assert {:done, ["B", "A"]} = result
    end
  end

  describe "pass + Throw" do
    test "pass propagates throw without applying transform" do
      comp =
        Writer.pass(
          Comp.bind(Writer.tell("before"), fn _ ->
            Comp.bind(Throw.throw(:error), fn _ ->
              Comp.pure({:done, fn logs -> Enum.reverse(logs) end})
            end)
          end)
        )
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Throw.with_handler()

      {result, _} = Comp.run(comp)

      assert {%Comp.Throw{error: :error}, ["before"]} = result
    end
  end

  # ============================================================
  # censor + Control Effects
  # ============================================================

  describe "censor + Yield" do
    test "censor applies transform after resume" do
      comp =
        Writer.censor(
          Comp.bind(Writer.tell("secret"), fn _ ->
            Comp.bind(Yield.yield(:pause), fn _ ->
              Comp.bind(Writer.tell("also secret"), fn _ ->
                Comp.pure(:done)
              end)
            end)
          end),
          fn _logs -> ["[REDACTED]"] end
        )
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Yield.with_handler()

      {%Comp.ExternalSuspend{resume: resume}, _} = Comp.run(comp)
      {result, _} = resume.(:ok)

      # All logs from censored scope should be redacted
      assert {:done, ["[REDACTED]"]} = result
    end

    test "censor with multiple yields transforms all logs" do
      comp =
        Writer.censor(
          Comp.bind(Writer.tell("a"), fn _ ->
            Comp.bind(Yield.yield(:y1), fn _ ->
              Comp.bind(Writer.tell("b"), fn _ ->
                Comp.bind(Yield.yield(:y2), fn _ ->
                  Comp.bind(Writer.tell("c"), fn _ ->
                    Comp.pure(:done)
                  end)
                end)
              end)
            end)
          end),
          fn logs -> Enum.map(logs, &String.upcase/1) end
        )
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Yield.with_handler()

      {%Comp.ExternalSuspend{resume: r1}, _} = Comp.run(comp)
      {%Comp.ExternalSuspend{resume: r2}, _} = r1.(:ok)
      {result, _} = r2.(:ok)

      assert {:done, ["C", "B", "A"]} = result
    end
  end

  describe "censor + Throw" do
    test "censor does not apply transform on throw" do
      comp =
        Writer.censor(
          Comp.bind(Writer.tell("secret"), fn _ ->
            Throw.throw(:error)
          end),
          fn _logs -> ["[REDACTED]"] end
        )
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Throw.with_handler()

      {result, _} = Comp.run(comp)

      # Transform not applied because throw short-circuits
      # The original log entry is preserved
      assert {%Comp.Throw{error: :error}, ["secret"]} = result
    end

    test "censor with catch_error - transform applies to recovered computation" do
      comp =
        Writer.censor(
          Throw.catch_error(
            Comp.bind(Writer.tell("before"), fn _ ->
              Throw.throw(:error)
            end),
            fn _err ->
              Comp.bind(Writer.tell("recovered"), fn _ ->
                Comp.pure(:caught)
              end)
            end
          ),
          fn logs -> Enum.map(logs, &String.upcase/1) end
        )
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)
        |> Throw.with_handler()

      {result, _} = Comp.run(comp)

      # Both "before" and "recovered" should be transformed
      assert {:caught, ["RECOVERED", "BEFORE"]} = result
    end
  end
end
