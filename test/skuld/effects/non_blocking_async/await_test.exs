defmodule Skuld.Effects.NonBlockingAsync.AwaitTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.NonBlockingAsync.Await
  alias Skuld.Effects.NonBlockingAsync.AwaitRequest
  alias Skuld.Effects.NonBlockingAsync.AwaitSuspend
  alias AwaitRequest.TaskTarget
  alias AwaitRequest.TimerTarget

  describe "await/1" do
    test "yields AwaitSuspend with the request" do
      task = Task.async(fn -> :ok end)
      request = AwaitRequest.new([TaskTarget.new(task)], :all)

      result =
        comp do
          _ <- Await.await(request)
          :done
        end
        |> Await.with_handler()
        |> Comp.run()

      assert {%AwaitSuspend{request: ^request}, _env} = result
    end

    test "resume function continues computation" do
      task = Task.async(fn -> :ok end)
      request = AwaitRequest.new([TaskTarget.new(task)], :all)

      {%AwaitSuspend{resume: resume}, _env} =
        comp do
          [result] <- Await.await(request)
          {:got, result}
        end
        |> Await.with_handler()
        |> Comp.run()

      # Resume with the "completed" results
      {final_result, _env} = resume.([:the_result])

      assert final_result == {:got, :the_result}
    end
  end

  describe "await_all/1" do
    test "creates :all mode request" do
      task1 = Task.async(fn -> :ok end)
      task2 = Task.async(fn -> :ok end)

      {%AwaitSuspend{request: request}, _env} =
        comp do
          _ <- Await.await_all([TaskTarget.new(task1), TaskTarget.new(task2)])
          :done
        end
        |> Await.with_handler()
        |> Comp.run()

      assert request.mode == :all
      assert length(request.targets) == 2
    end

    test "returns results in target order when resumed" do
      task1 = Task.async(fn -> :ok end)
      task2 = Task.async(fn -> :ok end)

      {%AwaitSuspend{resume: resume}, _env} =
        comp do
          results <- Await.await_all([TaskTarget.new(task1), TaskTarget.new(task2)])
          {:results, results}
        end
        |> Await.with_handler()
        |> Comp.run()

      {final, _env} = resume.([:first, :second])
      assert final == {:results, [:first, :second]}
    end
  end

  describe "await_any/1" do
    test "creates :any mode request" do
      task = Task.async(fn -> :ok end)
      timer = TimerTarget.new(1000)

      {%AwaitSuspend{request: request}, _env} =
        comp do
          _ <- Await.await_any([TaskTarget.new(task), timer])
          :done
        end
        |> Await.with_handler()
        |> Comp.run()

      assert request.mode == :any
      assert length(request.targets) == 2
    end

    test "returns winner and result when resumed" do
      task = Task.async(fn -> :ok end)
      timer = TimerTarget.new(1000)
      task_target = TaskTarget.new(task)

      {%AwaitSuspend{resume: resume}, _env} =
        comp do
          winner_result <- Await.await_any([task_target, timer])
          {:winner, winner_result}
        end
        |> Await.with_handler()
        |> Comp.run()

      # Scheduler would call resume with {winning_target, result}
      {final, _env} = resume.({task_target, :task_result})
      assert final == {:winner, {task_target, :task_result}}
    end
  end

  describe "chained awaits" do
    test "can await multiple times in sequence" do
      task1 = Task.async(fn -> :ok end)
      task2 = Task.async(fn -> :ok end)

      # First await
      {%AwaitSuspend{resume: resume1}, _env} =
        comp do
          [r1] <- Await.await_all([TaskTarget.new(task1)])
          [r2] <- Await.await_all([TaskTarget.new(task2)])
          {r1, r2}
        end
        |> Await.with_handler()
        |> Comp.run()

      # Resume first await - should yield second await
      {%AwaitSuspend{resume: resume2}, _env} = resume1.([:first])

      # Resume second await - should complete
      {final, _env} = resume2.([:second])

      assert final == {:first, :second}
    end
  end

  describe "without handler" do
    test "raises when await effect is not handled" do
      task = Task.async(fn -> :ok end)
      request = AwaitRequest.new([TaskTarget.new(task)], :all)

      assert_raise ArgumentError, ~r/No handler installed for effect/, fn ->
        comp do
          _ <- Await.await(request)
          :done
        end
        |> Comp.run!()
      end
    end
  end
end
