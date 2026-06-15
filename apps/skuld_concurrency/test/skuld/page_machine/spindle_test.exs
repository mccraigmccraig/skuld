defmodule Skuld.PageMachine.SpindleTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp.Env
  alias Skuld.Effects.Yield
  alias Skuld.PageMachine.Spindle
  alias Skuld.Coroutine

  defmodule TestFlow do
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

  defp wrap(comp), do: comp |> Yield.with_handler()

  describe "new/3" do
    test "creates a pending spindle with a key" do
      env = Env.new()
      spindle = Spindle.new(:cart, wrap(TestFlow.cart_flow()), env)
      assert %Spindle{key: :cart, ref: ref} = spindle
      assert is_reference(ref)
    end
  end

  describe "step/1" do
    test "runs a pending spindle to its first yield" do
      spindle = Spindle.new(:cart, wrap(TestFlow.cart_flow()), Env.new())
      assert {:yield, %Spindle{key: :cart}, :validating} = Spindle.step(spindle)
    end
  end

  describe "step/2 resume" do
    test "resumes a yielded spindle with a value" do
      spindle = Spindle.new(:cart, wrap(TestFlow.cart_flow()), Env.new())
      {:yield, spindle, :validating} = Spindle.step(spindle)
      {:complete, _spindle, {:valid, true}} = Spindle.step(spindle, 42)
    end
  end

  describe "tag_yield/2" do
    test "wraps yield values with the spindle key" do
      spindle = Spindle.new(:cart, wrap(TestFlow.cart_flow()), Env.new())
      {:yield, spindle, :validating} = Spindle.step(spindle)
      assert {:spindle, :cart, :validating} = Spindle.tag_yield(spindle, :validating)
    end
  end

  describe "cancel/2" do
    test "cancels a running spindle" do
      spindle = Spindle.new(:cart, wrap(TestFlow.cart_flow()), Env.new())
      {:yield, spindle, :validating} = Spindle.step(spindle)
      spindle = Spindle.cancel(spindle)
      assert %Coroutine.Cancelled{} = spindle.fiber
    end
  end

  describe "multiple spindles" do
    test "two spindles can run independently" do
      cart = Spindle.new(:cart, wrap(TestFlow.cart_flow()), Env.new())
      inv = Spindle.new(:inventory, wrap(TestFlow.inventory_flow()), Env.new())

      {:yield, cart, :validating} = Spindle.step(cart)
      {:yield, inv, :reserving} = Spindle.step(inv)

      {:complete, _cart, {:valid, true}} = Spindle.step(cart, 10)
      {:complete, _inv, {:ok, 99}} = Spindle.step(inv, 99)
    end
  end
end
