defmodule Skuld.PageMachine.SpindleTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Coroutine
  alias Skuld.Effects.FiberPool
  alias Skuld.Effects.FiberYield
  alias Skuld.Effects.Yield
  alias Skuld.PageMachine.Spindle

  defmodule TestFlows do
    use Skuld.Syntax

    defcomp cart_flow do
      step <- Yield.yield(:validating)
      valid = step >= 10
      {:valid, valid}
    end

    defcomp inventory_flow do
      reserved <- Yield.yield(:reserving)
      {:ok, reserved}
    end
  end

  defp wrap(comp) do
    comp
    |> Spindle.with_handler()
    |> FiberYield.with_handler()
    |> FiberPool.with_handler()
  end

  describe "fork/2" do
    test "creates a fiber and returns a Handle" do
      {handles, _env} =
        comp do
          h <- Spindle.fork(:cart, TestFlows.cart_flow())
          [h]
        end
        |> wrap()
        |> Comp.call(Env.new(), &Comp.identity_k/2)

      assert [%Coroutine.Handle{}] = handles
    end

    test "registers the key → fiber_id mapping in env state" do
      {_handles, env} =
        comp do
          h <- Spindle.fork(:cart, TestFlows.cart_flow())
          _i <- Spindle.fork(:inventory, TestFlows.inventory_flow())
          [h]
        end
        |> wrap()
        |> Comp.call(Env.new(), &Comp.identity_k/2)

      # Key mapping is written to env state
      mappings = Env.get_state(env, Spindle.env_key(), %Spindle.Mappings{})

      assert map_size(mappings.spindle_keys_by_fiber_id) == 2
      assert Spindle.Mappings.fiber_id(mappings, :cart)
      assert Spindle.Mappings.fiber_id(mappings, :inventory)
    end
  end
end
