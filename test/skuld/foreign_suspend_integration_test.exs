defmodule Skuld.ForeignSuspendIntegrationTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.ForeignSuspend
  alias Skuld.Coroutine
  alias Skuld.Coroutine.Completed
  alias Skuld.Coroutine.ForeignSuspensions
  alias Skuld.Effects.FiberPool

  describe "FiberPool bundling of foreign suspends" do
    test "single foreign suspend is collected and returned" do
      {agg, _env} =
        FiberPool.fiber(foreign_comp(:work_1))
        |> FiberPool.with_handler()
        |> Comp.run()

      assert %ForeignSuspensions{suspensions: suspends} = agg
      assert length(suspends) == 1
      assert %ForeignSuspend{id: :work_1, payload: :ref_work_1} = hd(suspends)
    end

    test "multiple foreign suspends are bundled together" do
      {agg, _env} =
        FiberPool.fiber_all([foreign_comp(:a), foreign_comp(:b), foreign_comp(:c)])
        |> FiberPool.with_handler()
        |> Comp.run()

      assert %ForeignSuspensions{suspensions: suspends} = agg
      assert length(suspends) == 3

      ids = Enum.map(suspends, & &1.id) |> Enum.sort()
      assert ids == [:a, :b, :c]
    end

    test "resolving all suspends via resume closure completes the computation" do
      comp =
        Comp.bind(FiberPool.fiber(foreign_comp(:task_1)), fn h ->
          FiberPool.await!(h)
        end)

      {agg, _env} =
        comp
        |> FiberPool.with_handler()
        |> Comp.run()

      assert %ForeignSuspensions{suspensions: suspends} = agg
      assert length(suspends) == 1

      # The main fiber is awaiting task_1 — so there's an InternalSuspend too.
      # After resolving task_1's ForeignSuspend, the scheduler should run
      # task_1 to completion (which was the foreign suspend), then continue
      # the main computation.
      #
      # Resolve the foreign suspend: task_1's resume gets 42, which becomes
      # task_1's result. The main fiber's await! then gets 42.

      resolved = Map.new(suspends, &{&1.id, 42})
      result = Coroutine.call(agg, resolved)

      # After resolving, the scheduler runs task_1 (which completes with 42),
      # then the main fiber resumes and gets 42 from await!

      assert %Completed{result: 42} = result
    end

    test "resolving one at a time through multiple rounds" do
      # Spawn three fibers that each produce a ForeignSuspend.
      # The main fiber awaits all of them.
      comp =
        Comp.bind(FiberPool.fiber(foreign_comp(:x)), fn h1 ->
          Comp.bind(FiberPool.fiber(foreign_comp(:y)), fn h2 ->
            Comp.bind(FiberPool.fiber(foreign_comp(:z)), fn h3 ->
              FiberPool.await_all!([h1, h2, h3])
            end)
          end)
        end)

      {agg, _env} =
        comp
        |> FiberPool.with_handler()
        |> Comp.run()

      assert %ForeignSuspensions{suspensions: suspends} = agg
      assert length(suspends) == 3

      # Resolve :x only — should still suspend since :y and :z are pending
      result1 = Coroutine.call(agg, %{x: 10})

      assert %ForeignSuspensions{suspensions: remaining} = result1
      remaining_ids = Enum.map(remaining, & &1.id) |> Enum.sort()
      assert remaining_ids == [:y, :z]

      # Resolve :y only
      result2 = Coroutine.call(result1, %{y: 20})

      assert %ForeignSuspensions{suspensions: remaining} = result2
      remaining_ids = Enum.map(remaining, & &1.id)
      assert remaining_ids == [:z]

      # Resolve the last one — :z
      result3 = Coroutine.call(result2, %{z: 30})

      assert %Completed{result: [10, 20, 30]} = result3
    end
  end

  # Helper: creates a computation that immediately yields a ForeignSuspend
  defp foreign_comp(id) do
    fn env, _k ->
      suspend = %ForeignSuspend{
        id: id,
        resume: fn val, env2 -> {val, env2} end,
        payload: String.to_atom("ref_#{id}")
      }

      {suspend, env}
    end
  end
end
