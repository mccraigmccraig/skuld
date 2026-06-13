defmodule Skuld.Coroutine.PageMachineTest do
  use ExUnit.Case, async: true

  alias Skuld.Coroutine.PageMachine
  alias Skuld.Effects.{Throw, Yield}

  doctest PageMachine

  defmodule TestFlow do
    use Skuld.Syntax

    defcomp flow(arg) do
      a <- Yield.yield(:first)
      b <- Yield.yield(:second)
      {:ok, {arg, a, b}}
    end
  end

  defmodule BrokenFlow do
    use Skuld.Syntax

    defcomp flow(arg) do
      _ <- Yield.yield(:start)
      {:ok, _} <- Throw.throw(:boom)
      {:ok, arg}
    end
  end

  defmodule ImmediateFlow do
    use Skuld.Syntax

    defcomp flow do
      42
    end
  end

  describe "run/1 + dispatch/1" do
    test "starts and dispatches first yield" do
      comp = TestFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()
      fiber = PageMachine.run(comp)
      assert {:yield, :first} = PageMachine.dispatch(fiber)
    end

    test "immediate completion" do
      comp = ImmediateFlow.flow()
      fiber = PageMachine.run(comp)
      assert {:complete, 42} = PageMachine.dispatch(fiber)
    end
  end

  describe "run/2 + dispatch/1" do
    test "resumes through all yields to completion" do
      comp = TestFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()

      fiber = PageMachine.run(comp)
      assert {:yield, :first} = PageMachine.dispatch(fiber)

      fiber = PageMachine.run(fiber, 10)
      assert {:yield, :second} = PageMachine.dispatch(fiber)

      fiber = PageMachine.run(fiber, 20)
      assert {:complete, {:ok, {:hello, 10, 20}}} = PageMachine.dispatch(fiber)
    end
  end

  describe "cancel/1 + dispatch/1" do
    test "cancels a yielded computation" do
      comp = TestFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()
      fiber = PageMachine.run(comp)
      fiber = PageMachine.cancel(fiber)
      assert {:cancel, :cancelled} = PageMachine.dispatch(fiber)
    end
  end

  describe "error handling" do
    test "dispatches thrown errors" do
      comp = BrokenFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()
      fiber = PageMachine.run(comp)
      fiber = PageMachine.run(fiber, :go)
      assert {:error, :boom} = PageMachine.dispatch(fiber)
    end
  end
end
