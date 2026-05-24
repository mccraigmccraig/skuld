defmodule Skuld.ForeignResolverTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.ForeignSuspend
  alias Skuld.Effects.FiberPool
  alias Skuld.ForeignResolver

  describe "ForeignResolver protocol" do
    test "Test resolver resolves immediately" do
      resolver = ForeignResolver.Test.new()

      suspends = [
        %ForeignSuspend{id: :a, resume: fn v, e -> {v, e} end, payload: :ref_a},
        %ForeignSuspend{id: :b, resume: fn v, e -> {v, e} end, payload: :ref_b}
      ]

      result_ref = make_ref()

      result =
        ForeignResolver.await_resolutions(resolver, suspends, fn resolved ->
          send(self(), {result_ref, resolved})
          :done
        end)

      assert result == :done
      assert_received {^result_ref, %{a: :ok, b: :ok}}
    end
  end

  describe "Comp.run/2 with ForeignResolver" do
    test "resolves foreign suspensions and returns result" do
      foreign_comp = fn id ->
        fn env, _k ->
          suspend = %ForeignSuspend{
            id: id,
            resume: fn val, env2 -> {val, env2} end,
            payload: :promise_ref
          }

          {suspend, env}
        end
      end

      result =
        FiberPool.fiber(foreign_comp.(:task_1))
        |> Comp.bind(fn h -> FiberPool.await!(h) end)
        |> FiberPool.with_handler()
        |> Comp.run(ForeignResolver.Test.new())

      assert result == :ok
    end

    test "multi-round resolution with remaining suspends" do
      foreign_comp = fn id ->
        fn env, _k ->
          suspend = %ForeignSuspend{
            id: id,
            resume: fn val, env2 -> {val, env2} end,
            payload: :ref
          }

          {suspend, env}
        end
      end

      result =
        FiberPool.fiber(foreign_comp.(:a))
        |> Comp.bind(fn h1 ->
          FiberPool.fiber(foreign_comp.(:b))
          |> Comp.bind(fn h2 ->
            FiberPool.fiber(foreign_comp.(:c))
            |> Comp.bind(fn h3 ->
              FiberPool.await_all!([h1, h2, h3])
            end)
          end)
        end)
        |> FiberPool.with_handler()
        |> Comp.run(ForeignResolver.Test.new())

      assert result == [:ok, :ok, :ok]
    end
  end
end
