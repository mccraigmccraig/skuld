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

  describe "run/1" do
    test "starts and returns {:yield, fiber, value}" do
      comp = TestFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()
      {:yield, %Skuld.Coroutine.ExternalSuspended{}, :first} = PageMachine.run(comp)
    end

    test "immediate completion returns {:complete, result}" do
      comp = ImmediateFlow.flow()
      assert {:complete, 42} = PageMachine.run(comp)
    end
  end

  describe "run/2" do
    test "resumes from yield tuple through all steps" do
      comp = TestFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()

      {:yield, fiber, :first} = PageMachine.run(comp)
      {:yield, fiber, :second} = PageMachine.run(fiber, 10)
      assert {:complete, {:ok, {:hello, 10, 20}}} = PageMachine.run(fiber, 20)
    end

    test "resumes from raw fiber too" do
      comp = TestFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()
      fiber = comp |> Skuld.Coroutine.new(Skuld.Comp.Env.new()) |> Skuld.Coroutine.run()
      {:yield, _, :first} = PageMachine.run(fiber)
    end
  end

  describe "cancel/1" do
    test "cancels a yielded computation from yield tuple" do
      comp = TestFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()
      {:yield, fiber, :first} = PageMachine.run(comp)
      assert {:cancel, :cancelled} = PageMachine.cancel(fiber)
    end
  end

  describe "error handling" do
    test "returns {:error, reason} for thrown errors" do
      comp = BrokenFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()
      {:yield, fiber, :start} = PageMachine.run(comp)
      assert {:error, :boom} = PageMachine.run(fiber, :go)
    end
  end
end
