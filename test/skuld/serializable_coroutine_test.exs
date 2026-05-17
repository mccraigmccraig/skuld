defmodule Skuld.SerializableCoroutineTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Coroutine
  alias Skuld.Effects.EffectLogger.Log
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Writer
  alias Skuld.Effects.Yield
  alias Skuld.SerializableCoroutine

  describe "new/2" do
    test "returns a SerializableCoroutine struct" do
      # credo:disable-for-next-line Skuld.Credo.CompPureRedundant
      pure_comp = Comp.pure(42)

      sc =
        SerializableCoroutine.new(pure_comp, fn comp ->
          comp |> Throw.with_handler()
        end)

      assert %SerializableCoroutine{} = sc

      %Coroutine.Completed{result: {42, log}} = SerializableCoroutine.run(sc)
      assert %Log{} = log
    end

    test "EffectLogger captures effects from user-installed handlers" do
      comp =
        comp do
          _ <- State.put(99)
          _ <- Writer.tell("hello")
          :ok
        end

      sc =
        SerializableCoroutine.new(comp, fn comp ->
          comp
          |> State.with_handler(0)
          |> Writer.with_handler([])
          |> Throw.with_handler()
        end)

      %Coroutine.Completed{result: {:ok, log}} = SerializableCoroutine.run(sc)
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

      sc =
        SerializableCoroutine.new(comp, fn comp ->
          comp
          |> State.with_handler(0)
          |> Yield.with_handler()
          |> Throw.with_handler()
        end)

      %Coroutine.ExternalSuspended{value: value} =
        suspended =
        SerializableCoroutine.run(sc)

      assert value == :paused
      assert %Log{} = SerializableCoroutine.get_log(suspended)
    end

    test "can resume from serialized log via run/3" do
      comp =
        comp do
          x <- Yield.yield(:need_input)
          {:ok, x}
        end

      sc =
        SerializableCoroutine.new(comp, fn comp ->
          comp |> Yield.with_handler() |> Throw.with_handler()
        end)

      suspended = SerializableCoroutine.run(sc)
      log = SerializableCoroutine.get_log(suspended)
      json = SerializableCoroutine.serialize(log)
      {:ok, deserialized_log} = SerializableCoroutine.deserialize(json)

      %Coroutine.Completed{result: {{:ok, :the_answer}, _}} =
        SerializableCoroutine.run(deserialized_log, sc, :the_answer)
    end

    test "can yield multiple times with serialize/resume cycle" do
      comp =
        comp do
          _ <- Yield.yield(:step_one)
          _ <- Yield.yield(:step_two)
          :done
        end

      sc =
        SerializableCoroutine.new(comp, fn comp ->
          comp |> Yield.with_handler() |> Throw.with_handler()
        end)

      suspended1 = SerializableCoroutine.run(sc)
      assert %Coroutine.ExternalSuspended{value: :step_one} = suspended1

      log1 = SerializableCoroutine.get_log(suspended1)
      json1 = SerializableCoroutine.serialize(log1)
      {:ok, log1d} = SerializableCoroutine.deserialize(json1)

      suspended2 = SerializableCoroutine.run(log1d, sc, :go)
      assert %Coroutine.ExternalSuspended{value: :step_two} = suspended2

      log2 = SerializableCoroutine.get_log(suspended2)
      json2 = SerializableCoroutine.serialize(log2)
      {:ok, log2d} = SerializableCoroutine.deserialize(json2)

      %Coroutine.Completed{result: {:done, _log}} =
        SerializableCoroutine.run(log2d, sc, :continue)
    end

    test "can resume from serialized JSON string via run/3" do
      comp =
        comp do
          x <- Yield.yield(:need_input)
          {:ok, x}
        end

      sc =
        SerializableCoroutine.new(comp, fn comp ->
          comp |> Yield.with_handler() |> Throw.with_handler()
        end)

      suspended = SerializableCoroutine.run(sc)
      json = SerializableCoroutine.serialize(SerializableCoroutine.get_log(suspended))

      %Coroutine.Completed{result: {{:ok, :direct_value}, _}} =
        SerializableCoroutine.run(json, sc, :direct_value)
    end

    test "can resume a live suspended fiber via run/2" do
      comp =
        comp do
          x <- Yield.yield(:need_input)
          {:ok, x}
        end

      sc =
        SerializableCoroutine.new(comp, fn comp ->
          comp |> Yield.with_handler() |> Throw.with_handler()
        end)

      suspended = SerializableCoroutine.run(sc)

      %Coroutine.Completed{result: {{:ok, :live_resume}, _}} =
        SerializableCoroutine.run(suspended, :live_resume)
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
