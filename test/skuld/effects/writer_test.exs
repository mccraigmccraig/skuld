defmodule Skuld.Effects.WriterTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.Writer

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
end
