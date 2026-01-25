defmodule Skuld.Effects.NonBlockingAsync.AwaitSuspendTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.NonBlockingAsync.AwaitSuspend
  alias Skuld.Effects.NonBlockingAsync.AwaitRequest
  alias AwaitRequest.TaskTarget
  alias AwaitRequest.TimerTarget
  alias Skuld.Comp.ISentinel

  describe "AwaitSuspend struct" do
    test "can be created with request and resume" do
      request = make_request()
      resume = fn result -> {:done, result} end

      suspend = %AwaitSuspend{request: request, resume: resume}

      assert suspend.request == request
      assert is_function(suspend.resume, 1)
    end
  end

  describe "ISentinel protocol" do
    test "sentinel?/1 returns true" do
      suspend = make_await_suspend()
      assert ISentinel.sentinel?(suspend)
    end

    test "get_resume/1 returns the resume function" do
      resume = fn result -> {:done, result} end
      suspend = %AwaitSuspend{request: make_request(), resume: resume}

      assert ISentinel.get_resume(suspend) == resume
    end

    test "with_resume/2 replaces the resume function" do
      suspend = make_await_suspend()
      new_resume = fn result -> {:new, result} end

      updated = ISentinel.with_resume(suspend, new_resume)

      assert ISentinel.get_resume(updated) == new_resume
      assert updated.request == suspend.request
    end

    test "run!/1 raises with helpful message" do
      suspend = make_await_suspend()

      assert_raise RuntimeError,
                   ~r/Computation suspended on await.*Scheduler/,
                   fn -> ISentinel.run!(suspend) end
    end

    test "serializable_payload/1 returns request info without resume" do
      task = Task.async(fn -> :ok end)
      timer = TimerTarget.new(1000)
      request = AwaitRequest.new([TaskTarget.new(task), timer], :any)
      suspend = %AwaitSuspend{request: request, resume: fn _ -> :ok end}

      payload = ISentinel.serializable_payload(suspend)

      assert %{await_request: req_info} = payload
      assert req_info.mode == :any
      assert req_info.target_count == 2
      assert req_info.target_types == [:task, :timer]
      assert is_binary(req_info.id)

      # Verify resume function is not in payload
      refute Map.has_key?(payload, :resume)
    end
  end

  # Helpers

  defp make_request do
    task = Task.async(fn -> :ok end)
    AwaitRequest.new([TaskTarget.new(task)], :all)
  end

  defp make_await_suspend do
    %AwaitSuspend{
      request: make_request(),
      resume: fn result -> {:done, result} end
    }
  end
end
