defmodule Skuld.SerializableCoroutineTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Coroutine
  alias Skuld.Effects.{EffectLogger, State, Throw, Yield, Writer}
  alias Skuld.Effects.EffectLogger.Log
  alias Skuld.SerializableCoroutine

  describe "new/2" do
    test "returns a runnable Coroutine" do
      coroutine =
        SerializableCoroutine.new(Comp.pure(42), fn comp ->
          comp |> Throw.with_handler()
        end)

      assert %Coroutine.Pending{} = coroutine

      %Coroutine.Completed{result: {42, log}} = Coroutine.run(coroutine)
      assert %Log{} = log
    end

    test "EffectLogger captures effects from user-installed handlers" do
      comp =
        comp do
          _ <- State.put(99)
          _ <- Writer.tell("hello")
          :ok
        end

      coroutine =
        SerializableCoroutine.new(comp, fn comp ->
          comp
          |> State.with_handler(0)
          |> Writer.with_handler([])
          |> Throw.with_handler()
        end)

      %Coroutine.Completed{result: {:ok, log}} = Coroutine.run(coroutine)
      log_list = Log.to_list(log)
      sigs = Enum.map(log_list, & &1.sig)
      assert Skuld.Effects.State in sigs
      assert Skuld.Effects.Writer in sigs
    end
  end

  describe "with Yield" do
    test "suspended coroutine carries yielded value and log" do
      comp =
        comp do
          _ <- State.put(1)
          _ <- Yield.yield(:paused)
          :done
        end

      coroutine =
        SerializableCoroutine.new(comp, fn comp ->
          comp
          |> State.with_handler(0)
          |> Yield.with_handler()
          |> Throw.with_handler()
        end)

      %Coroutine.ExternalSuspended{value: value} =
        suspended =
        Coroutine.run(coroutine)

      assert value == :paused
      assert %Log{} = SerializableCoroutine.get_log(suspended)
    end

    test "can resume from serialized log" do
      comp =
        comp do
          x <- Yield.yield(:need_input)
          {:ok, x}
        end

      handlers_fun = fn comp ->
        comp |> Yield.with_handler() |> Throw.with_handler()
      end

      coroutine = SerializableCoroutine.new(comp, handlers_fun)

      suspended = Coroutine.run(coroutine)
      log = SerializableCoroutine.get_log(suspended)
      json = SerializableCoroutine.serialize(log)
      {:ok, deserialized_log} = SerializableCoroutine.deserialize(json)

      resume_coroutine =
        comp
        |> EffectLogger.with_resume(deserialized_log, :the_answer)
        |> handlers_fun.()
        |> then(&Coroutine.new(&1, Env.new()))

      %Coroutine.Completed{result: {{:ok, :the_answer}, _}} = Coroutine.run(resume_coroutine)
    end

    test "can yield multiple times with serialize/resume cycle" do
      comp =
        comp do
          _ <- Yield.yield(:step_one)
          _ <- Yield.yield(:step_two)
          :done
        end

      handlers_fun = fn comp ->
        comp |> Yield.with_handler() |> Throw.with_handler()
      end

      coroutine = SerializableCoroutine.new(comp, handlers_fun)

      suspended1 = Coroutine.run(coroutine)
      assert %Coroutine.ExternalSuspended{value: :step_one} = suspended1

      log1 = SerializableCoroutine.get_log(suspended1)
      json1 = SerializableCoroutine.serialize(log1)
      {:ok, log1d} = SerializableCoroutine.deserialize(json1)

      resume1_coroutine =
        comp
        |> EffectLogger.with_resume(log1d, :go)
        |> handlers_fun.()
        |> then(&Coroutine.new(&1, Env.new()))

      suspended2 = Coroutine.run(resume1_coroutine)
      assert %Coroutine.ExternalSuspended{value: :step_two} = suspended2

      log2 = SerializableCoroutine.get_log(suspended2)
      json2 = SerializableCoroutine.serialize(log2)
      {:ok, log2d} = SerializableCoroutine.deserialize(json2)

      resume2_coroutine =
        comp
        |> EffectLogger.with_resume(log2d, :continue)
        |> handlers_fun.()
        |> then(&Coroutine.new(&1, Env.new()))

      %Coroutine.Completed{result: {:done, _log}} = Coroutine.run(resume2_coroutine)
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trips the log" do
      log = Log.new()

      json = SerializableCoroutine.serialize(log)
      assert is_binary(json)

      {:ok, deserialized} = SerializableCoroutine.deserialize(json)
      assert %Log{} = deserialized
    end
  end
end
