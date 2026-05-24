defmodule Skuld.ForeignResolverIntegrationTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.ForeignSuspend
  alias Skuld.Effects.FiberPool
  alias Skuld.Test.Adder
  alias Skuld.Test.Doubler
  alias Skuld.Test.Mapper
  alias Skuld.Test.MultiRound

  defp foreign_comp(id) do
    fn env, _k ->
      suspend = %ForeignSuspend{
        id: id,
        resume: fn val, env2 -> {val, env2} end,
        payload: id
      }

      {suspend, env}
    end
  end

  describe "Comp.run/2 with resolver" do
    test "resolves three fibers with Doubler (payload * 2)" do
      result =
        comp do
          h1 <- FiberPool.fiber(foreign_comp(1))
          h2 <- FiberPool.fiber(foreign_comp(2))
          h3 <- FiberPool.fiber(foreign_comp(3))
          FiberPool.await_all!([h1, h2, h3])
        end
        |> FiberPool.with_handler()
        |> Comp.run(Doubler.new())

      assert result == [2, 4, 6]
    end

    test "resolves with Adder adding 100 to each payload" do
      result =
        comp do
          h1 <- FiberPool.fiber(foreign_comp(5))
          h2 <- FiberPool.fiber(foreign_comp(10))
          FiberPool.await_all!([h1, h2])
        end
        |> FiberPool.with_handler()
        |> Comp.run(Adder.new(100))

      assert result == [105, 110]
    end

    test "resolves with Mapper applying a function to payloads" do
      mapper = Mapper.new(fn n -> "value_#{n}" end)

      result =
        comp do
          h <- FiberPool.fiber(foreign_comp(:hello))
          FiberPool.await!(h)
        end
        |> FiberPool.with_handler()
        |> Comp.run(mapper)

      assert result == "value_hello"
    end

    test "resolves in multiple rounds with MultiRound" do
      result =
        comp do
          h1 <- FiberPool.fiber(foreign_comp(1))
          h2 <- FiberPool.fiber(foreign_comp(2))
          h3 <- FiberPool.fiber(foreign_comp(3))
          h4 <- FiberPool.fiber(foreign_comp(4))
          FiberPool.await_all!([h1, h2, h3, h4])
        end
        |> FiberPool.with_handler()
        |> Comp.run(MultiRound.new())

      # Round 1: resolves first 2 → 1*10=10, 2*10=20
      # Round 2: resolves last 2 → 3*10=30, 4*10=40
      assert result == [10, 20, 30, 40]
    end

    test "single pure value (no foreign suspends) returns immediately" do
      result =
        comp do
          42
        end
        |> Comp.run(Doubler.new())

      assert result == 42
    end

    test "error propagates through resolver" do
      boom = fn _env, _k -> raise "exploded" end

      result =
        FiberPool.fiber(boom)
        |> Comp.bind(fn h -> FiberPool.await!(h) end)
        |> FiberPool.with_handler()
        |> Comp.run(Doubler.new())

      assert %Comp.Throw{} = result
    end
  end
end
