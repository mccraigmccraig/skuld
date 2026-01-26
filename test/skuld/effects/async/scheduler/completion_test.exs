defmodule Skuld.Effects.Async.Scheduler.CompletionTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.Async.Scheduler.Completion
  alias Skuld.AsyncComputation
  alias Skuld.Comp.Cancelled
  alias Skuld.Comp.Suspend
  alias Skuld.Comp.Throw

  describe "Task messages" do
    test "matches task success {ref, result}" do
      ref = make_ref()
      msg = {ref, :task_result}

      assert {:completed, {:task, ^ref}, {:ok, :task_result}} = Completion.match(msg)
    end

    test "matches task failure {:DOWN, ...}" do
      ref = make_ref()
      pid = self()
      msg = {:DOWN, ref, :process, pid, :normal}

      assert {:completed, {:task, ^ref}, {:error, {:down, :normal}}} = Completion.match(msg)
    end

    test "matches task crash with reason" do
      ref = make_ref()
      pid = self()
      msg = {:DOWN, ref, :process, pid, {:error, %RuntimeError{message: "oops"}}}

      assert {:completed, {:task, ^ref}, {:error, {:down, reason}}} = Completion.match(msg)
      assert {:error, %RuntimeError{}} = reason
    end
  end

  describe "Timer messages" do
    test "matches timer fired {:timeout, ref, msg}" do
      ref = make_ref()
      msg = {:timeout, ref, :fired}

      assert {:completed, {:timer, ^ref}, {:ok, :timeout}} = Completion.match(msg)
    end

    test "timer message preserves ref for correlation" do
      ref = make_ref()
      msg = {:timeout, ref, :anything}

      {:completed, {:timer, matched_ref}, _} = Completion.match(msg)
      assert matched_ref == ref
    end
  end

  describe "AsyncComputation messages" do
    test "matches computation success" do
      tag = :my_computation
      msg = {AsyncComputation, tag, :computation_result}

      assert {:completed, {:computation, ^tag}, {:ok, :computation_result}} =
               Completion.match(msg)
    end

    test "matches computation yield as special case" do
      tag = :my_computation
      suspend = %Suspend{value: :need_input, resume: nil, data: nil}
      msg = {AsyncComputation, tag, suspend}

      assert {:yielded, {:computation, ^tag}, ^suspend} = Completion.match(msg)
    end

    test "matches computation throw" do
      tag = :my_computation
      thrown = %Throw{error: :validation_failed}
      msg = {AsyncComputation, tag, thrown}

      assert {:completed, {:computation, ^tag}, {:error, {:throw, :validation_failed}}} =
               Completion.match(msg)
    end

    test "matches computation cancelled" do
      tag = :my_computation
      cancelled = %Cancelled{reason: :timeout}
      msg = {AsyncComputation, tag, cancelled}

      assert {:completed, {:computation, ^tag}, {:error, {:cancelled, :timeout}}} =
               Completion.match(msg)
    end

    test "computation tag can be any term" do
      # Tag could be an atom
      assert {:completed, {:computation, :atom_tag}, _} =
               Completion.match({AsyncComputation, :atom_tag, :result})

      # Tag could be a tuple
      assert {:completed, {:computation, {:user, 123}}, _} =
               Completion.match({AsyncComputation, {:user, 123}, :result})

      # Tag could be a reference
      ref = make_ref()

      assert {:completed, {:computation, ^ref}, _} =
               Completion.match({AsyncComputation, ref, :result})
    end
  end

  describe "Unknown messages" do
    test "returns :unknown for unrecognized format" do
      assert :unknown == Completion.match(:random_atom)
      assert :unknown == Completion.match({:some, :tuple})
      assert :unknown == Completion.match({:DOWN, :not_a_ref, :process, self(), :normal})
      assert :unknown == Completion.match(%{map: :message})
    end

    test "returns :unknown for GenServer call/cast messages" do
      assert :unknown == Completion.match({:"$gen_call", {self(), make_ref()}, :request})
      assert :unknown == Completion.match({:"$gen_cast", :message})
    end
  end

  describe "integration with actual Task" do
    test "matches real Task.async completion" do
      task = Task.async(fn -> :real_result end)
      ref = task.ref

      # Wait for completion message
      assert_receive msg, 100
      assert {:completed, {:task, ^ref}, {:ok, :real_result}} = Completion.match(msg)
    end

    test "matches real Task DOWN message" do
      # Simulate a task DOWN message (what we'd get if we monitored)
      ref = make_ref()
      pid = spawn(fn -> :ok end)
      msg = {:DOWN, ref, :process, pid, :normal}

      assert {:completed, {:task, ^ref}, {:error, {:down, :normal}}} = Completion.match(msg)
    end
  end
end
