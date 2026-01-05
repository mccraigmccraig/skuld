defmodule Skuld.Effects.TaggedWriterTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.TaggedWriter

  describe "tell" do
    test "appends message to log for tag" do
      comp =
        Comp.bind(TaggedWriter.tell(:audit, "msg1"), fn _ ->
          Comp.bind(TaggedWriter.tell(:audit, "msg2"), fn _ ->
            TaggedWriter.peek(:audit)
          end)
        end)
        |> TaggedWriter.with_handler(:audit)

      {result, _env} = Comp.run(comp)
      # Logs are in reverse chronological order
      assert ["msg2", "msg1"] = result
    end

    test "multiple tags accumulate independently" do
      comp =
        Comp.bind(TaggedWriter.tell(:audit, "audit1"), fn _ ->
          Comp.bind(TaggedWriter.tell(:metrics, "metric1"), fn _ ->
            Comp.bind(TaggedWriter.tell(:audit, "audit2"), fn _ ->
              Comp.bind(TaggedWriter.tell(:metrics, "metric2"), fn _ ->
                Comp.bind(TaggedWriter.peek(:audit), fn audit_log ->
                  Comp.bind(TaggedWriter.peek(:metrics), fn metrics_log ->
                    Comp.pure({audit_log, metrics_log})
                  end)
                end)
              end)
            end)
          end)
        end)
        |> TaggedWriter.with_handler(:audit)
        |> TaggedWriter.with_handler(:metrics)

      {{audit_log, metrics_log}, _env} = Comp.run(comp)
      assert ["audit2", "audit1"] = audit_log
      assert ["metric2", "metric1"] = metrics_log
    end
  end

  describe "peek" do
    test "reads current log for tag" do
      comp =
        Comp.bind(TaggedWriter.tell(:log, "first"), fn _ ->
          Comp.bind(TaggedWriter.tell(:log, "second"), fn _ ->
            TaggedWriter.peek(:log)
          end)
        end)
        |> TaggedWriter.with_handler(:log)

      {result, _env} = Comp.run(comp)
      assert ["second", "first"] = result
    end
  end

  describe "listen" do
    test "captures log output for tag during computation" do
      comp =
        Comp.bind(TaggedWriter.tell(:log, "before"), fn _ ->
          inner =
            TaggedWriter.listen(
              :log,
              Comp.bind(TaggedWriter.tell(:log, "inner1"), fn _ ->
                Comp.bind(TaggedWriter.tell(:log, "inner2"), fn _ ->
                  Comp.pure(:result)
                end)
              end)
            )

          Comp.bind(inner, fn {result, captured} ->
            Comp.bind(TaggedWriter.tell(:log, "after"), fn _ ->
              Comp.bind(TaggedWriter.peek(:log), fn full_log ->
                Comp.pure({result, captured, full_log})
              end)
            end)
          end)
        end)
        |> TaggedWriter.with_handler(:log)

      {{:result, captured, full_log}, _env} = Comp.run(comp)
      assert ["inner2", "inner1"] = captured
      # Full log includes all messages
      assert ["after", "inner2", "inner1", "before"] = full_log
    end

    test "listen on one tag does not capture other tags" do
      comp =
        Comp.bind(
          TaggedWriter.listen(
            :a,
            Comp.bind(TaggedWriter.tell(:a, "a-msg"), fn _ ->
              Comp.bind(TaggedWriter.tell(:b, "b-msg"), fn _ ->
                Comp.pure(:ok)
              end)
            end)
          ),
          fn {result, captured_a} ->
            Comp.bind(TaggedWriter.peek(:b), fn b_log ->
              Comp.pure({result, captured_a, b_log})
            end)
          end
        )
        |> TaggedWriter.with_handler(:a)
        |> TaggedWriter.with_handler(:b)

      {{:ok, captured_a, b_log}, _env} = Comp.run(comp)
      assert ["a-msg"] = captured_a
      assert ["b-msg"] = b_log
    end
  end

  describe "censor" do
    test "transforms logs for tag during computation" do
      comp =
        Comp.bind(
          TaggedWriter.censor(
            :log,
            Comp.bind(TaggedWriter.tell(:log, "secret"), fn _ ->
              Comp.pure(:done)
            end),
            fn logs -> Enum.map(logs, fn _ -> "[REDACTED]" end) end
          ),
          fn result ->
            Comp.bind(TaggedWriter.peek(:log), fn log ->
              Comp.pure({result, log})
            end)
          end
        )
        |> TaggedWriter.with_handler(:log)

      {{:done, log}, _env} = Comp.run(comp)
      assert ["[REDACTED]"] = log
    end
  end

  describe "with_handler/3" do
    test "installs handler and initializes log for tag" do
      comp =
        Comp.bind(TaggedWriter.tell(:log, "msg"), fn _ ->
          TaggedWriter.peek(:log)
        end)
        |> TaggedWriter.with_handler(:log)

      {result, _env} = Comp.run(comp)
      assert ["msg"] = result
    end

    test "with initial log entries" do
      comp =
        Comp.bind(TaggedWriter.tell(:log, "new"), fn _ ->
          TaggedWriter.peek(:log)
        end)
        |> TaggedWriter.with_handler(:log, ["existing"])

      {result, _env} = Comp.run(comp)
      assert ["new", "existing"] = result
    end

    test "shadows outer handler of same tag and restores it" do
      comp =
        Comp.bind(TaggedWriter.tell(:log, "outer1"), fn _ ->
          inner =
            Comp.bind(TaggedWriter.tell(:log, "inner1"), fn _ ->
              TaggedWriter.peek(:log)
            end)
            |> TaggedWriter.with_handler(:log)

          Comp.bind(inner, fn inner_log ->
            Comp.bind(TaggedWriter.tell(:log, "outer2"), fn _ ->
              Comp.bind(TaggedWriter.peek(:log), fn outer_log ->
                Comp.pure({inner_log, outer_log})
              end)
            end)
          end)
        end)
        |> TaggedWriter.with_handler(:log)

      {{inner_log, outer_log}, _env} = Comp.run(comp)
      assert ["inner1"] = inner_log
      assert ["outer2", "outer1"] = outer_log
    end

    test "cleanup on throw" do
      alias Skuld.Effects.Throw

      comp =
        Throw.catch_error(
          Comp.bind(
            Comp.bind(TaggedWriter.tell(:log, "inner"), fn _ ->
              Throw.throw(:error)
            end)
            |> TaggedWriter.with_handler(:log),
            fn _ -> Comp.pure(:unreachable) end
          ),
          fn _error ->
            Comp.bind(TaggedWriter.tell(:log, "after_catch"), fn _ ->
              TaggedWriter.peek(:log)
            end)
          end
        )
        |> TaggedWriter.with_handler(:log)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      # Outer log preserved, inner log discarded
      assert ["after_catch"] = result
    end

    test "composable with untagged Writer" do
      alias Skuld.Effects.Writer

      comp =
        Comp.bind(TaggedWriter.tell(:tagged, "tagged_msg"), fn _ ->
          Comp.bind(Writer.tell("untagged_msg"), fn _ ->
            Comp.bind(TaggedWriter.peek(:tagged), fn tagged_log ->
              Comp.bind(Writer.peek(), fn untagged_log ->
                Comp.pure({tagged_log, untagged_log})
              end)
            end)
          end)
        end)
        |> TaggedWriter.with_handler(:tagged)
        |> Writer.with_handler()

      {{tagged_log, untagged_log}, _env} = Comp.run(comp)
      assert ["tagged_msg"] = tagged_log
      assert ["untagged_msg"] = untagged_log
    end
  end

  describe "tell_many" do
    test "tells multiple messages" do
      comp =
        Comp.bind(TaggedWriter.tell_many(:log, ["a", "b", "c"]), fn _ ->
          TaggedWriter.peek(:log)
        end)
        |> TaggedWriter.with_handler(:log)

      {result, _env} = Comp.run(comp)
      assert ["c", "b", "a"] = result
    end
  end

  describe "clear" do
    test "clears log for tag" do
      comp =
        Comp.bind(TaggedWriter.tell(:log, "msg1"), fn _ ->
          Comp.bind(TaggedWriter.clear(:log), fn _ ->
            Comp.bind(TaggedWriter.tell(:log, "msg2"), fn _ ->
              TaggedWriter.peek(:log)
            end)
          end)
        end)
        |> TaggedWriter.with_handler(:log)

      {result, _env} = Comp.run(comp)
      assert ["msg2"] = result
    end
  end

  describe "with_handler output" do
    test "includes final log in result" do
      comp =
        Comp.bind(TaggedWriter.tell(:audit, "step 1"), fn _ ->
          Comp.bind(TaggedWriter.tell(:audit, "step 2"), fn _ ->
            Comp.pure(:done)
          end)
        end)
        |> TaggedWriter.with_handler(:audit, [],
          output: fn result, log -> {result, log} end
        )

      {result, _env} = Comp.run(comp)

      assert {:done, ["step 2", "step 1"]} = result
    end

    test "with custom transformation" do
      comp =
        Comp.bind(TaggedWriter.tell(:log, "a"), fn _ ->
          Comp.bind(TaggedWriter.tell(:log, "b"), fn _ ->
            Comp.bind(TaggedWriter.tell(:log, "c"), fn _ ->
              Comp.pure(42)
            end)
          end)
        end)
        |> TaggedWriter.with_handler(:log, [],
          output: fn result, log -> %{value: result, count: length(log)} end
        )

      {result, _env} = Comp.run(comp)

      assert %{value: 42, count: 3} = result
    end

    test "with initial log entries" do
      comp =
        Comp.bind(TaggedWriter.tell(:log, "new"), fn _ ->
          Comp.pure(:ok)
        end)
        |> TaggedWriter.with_handler(:log, ["existing"],
          output: fn result, log -> {result, log} end
        )

      {result, _env} = Comp.run(comp)

      assert {:ok, ["new", "existing"]} = result
    end
  end
end
