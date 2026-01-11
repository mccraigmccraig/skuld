defmodule Skuld.Effects.MarkLoopTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.EffectLogger

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
  end

  describe "EffectLogger.mark_loop/2" do
    test "accepts checkpoint data" do
      checkpoint = %{messages: ["hello", "world"], counter: 42}

      {{:done, _log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, checkpoint)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()
    end

    test "checkpoint can be nil" do
      {{:done, _log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, nil)
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()
    end
  end

  describe "multiple marks in sequence" do
    test "allows multiple marks of the same loop_id" do
      {{:done, _log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(TestLoop, %{iteration: 1})
          _ <- EffectLogger.mark_loop(TestLoop, %{iteration: 2})
          _ <- EffectLogger.mark_loop(TestLoop, %{iteration: 3})
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()
    end

    test "allows nested marks of different loop_ids" do
      {{:done, _log}, _env} =
        comp do
          _ <- EffectLogger.mark_loop(OuterLoop, %{outer: 1})
          _ <- EffectLogger.mark_loop(InnerLoop, %{inner: 1})
          _ <- EffectLogger.mark_loop(InnerLoop, %{inner: 2})
          _ <- EffectLogger.mark_loop(OuterLoop, %{outer: 2})
          _ <- EffectLogger.mark_loop(InnerLoop, %{inner: 1})
          return(:done)
        end
        |> EffectLogger.with_logging()
        |> Comp.run()
    end
  end
end
