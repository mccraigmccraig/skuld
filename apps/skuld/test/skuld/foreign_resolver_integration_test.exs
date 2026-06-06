defmodule Skuld.ForeignResolverIntegrationTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.ForeignSuspend
  alias Skuld.Effects.FiberPool
  alias Skuld.ForeignResolver.Runner

  defp foreign_comp(id, payload) do
    fn env, _k ->
      suspend = %ForeignSuspend{
        id: id,
        resume: fn val, env2 -> {val, env2} end,
        payload: payload
      }

      {suspend, env}
    end
  end

  describe "ForeignResolver.Runner.run/1" do
    test "resolves three fibers with Doubler payloads (value * 2)" do
      result =
        comp do
          h1 <- FiberPool.fiber(foreign_comp(1, %Skuld.Test.Doubler{value: 1}))
          h2 <- FiberPool.fiber(foreign_comp(2, %Skuld.Test.Doubler{value: 2}))
          h3 <- FiberPool.fiber(foreign_comp(3, %Skuld.Test.Doubler{value: 3}))
          FiberPool.await_all!([h1, h2, h3])
        end
        |> FiberPool.with_handler()
        |> Runner.run()

      assert result == [2, 4, 6]
    end

    test "resolves with Adder payloads (value + 100)" do
      result =
        comp do
          h1 <- FiberPool.fiber(foreign_comp(5, %Skuld.Test.Adder{value: 5}))
          h2 <- FiberPool.fiber(foreign_comp(10, %Skuld.Test.Adder{value: 10}))
          FiberPool.await_all!([h1, h2])
        end
        |> FiberPool.with_handler()
        |> Runner.run()

      assert result == [105, 110]
    end

    test "resolves with Mapper payloads (payload value)" do
      result =
        comp do
          h <- FiberPool.fiber(foreign_comp(:task, %Skuld.Test.Mapper{value: "hello_world"}))
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> Runner.run()

      assert result == "hello_world"
    end

    test "resolves in multiple rounds with MultiRound payloads" do
      result =
        comp do
          h1 <- FiberPool.fiber(foreign_comp(1, %Skuld.Test.MultiRound{value: 1}))
          h2 <- FiberPool.fiber(foreign_comp(2, %Skuld.Test.MultiRound{value: 2}))
          h3 <- FiberPool.fiber(foreign_comp(3, %Skuld.Test.MultiRound{value: 3}))
          h4 <- FiberPool.fiber(foreign_comp(4, %Skuld.Test.MultiRound{value: 4}))
          FiberPool.await_all!([h1, h2, h3, h4])
        end
        |> FiberPool.with_handler()
        |> Runner.run()

      # Round 1: resolves first 2 → 1*10=10, 2*10=20
      # Round 2: resolves last 2 → 3*10=30, 4*10=40
      assert result == [10, 20, 30, 40]
    end

    test "single pure value (no foreign suspends) returns immediately" do
      result =
        comp do
          42
        end
        |> Runner.run()

      assert result == 42
    end

    test "error propagates through resolution" do
      boom = fn _env, _k -> raise "exploded" end

      result =
        FiberPool.fiber(boom)
        |> Comp.bind(fn h -> FiberPool.await!(h) end)
        |> FiberPool.with_handler()
        |> Runner.run()

      assert %Comp.Throw{} = result
    end
  end
end
