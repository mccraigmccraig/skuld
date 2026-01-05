defmodule Skuld.Effects.WriterTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.Writer
  alias Skuld.Effects.Yield
  alias Skuld.Effects.Throw

  describe "with_handler output" do
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
      {%Comp.Suspend{value: :pause, resume: resume}, _env} = Comp.run(comp)

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

      {%Comp.Suspend{resume: r1}, _} = Comp.run(comp)
      {%Comp.Suspend{resume: r2}, _} = r1.("b")
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

      {%Comp.Suspend{resume: resume}, _} = Comp.run(comp)
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

      {%Comp.Suspend{resume: resume}, _} = Comp.run(comp)
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

      {%Comp.Suspend{resume: resume}, _} = Comp.run(comp)
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

      {%Comp.Suspend{resume: r1}, _} = Comp.run(comp)
      {%Comp.Suspend{resume: r2}, _} = r1.(:ok)
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
