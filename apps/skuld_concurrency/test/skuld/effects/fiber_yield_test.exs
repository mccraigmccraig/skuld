defmodule Skuld.Effects.FiberYieldTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Effects.FiberYield
  alias Skuld.Effects.Yield

  defp call(comp, env), do: Comp.call(comp, env, &Comp.identity_k/2)

  describe "FiberYield.handle/3" do
    test "produces InternalSuspend with FiberYield payload" do
      comp =
        Yield.yield(:step_one)
        |> FiberYield.with_handler()

      env = Env.new()

      {result, _env} = call(comp, env)
      assert %InternalSuspend{payload: %InternalSuspend.FiberYield{value: :step_one}} = result
    end

    test "resume function continues from yield point" do
      comp =
        comp do
          a <- Yield.yield(:ask)
          {:got, a}
        end
        |> FiberYield.with_handler()

      env = Env.new()

      # First call: produces FiberYield
      {result, env} = call(comp, env)
      assert %InternalSuspend{resume: resume} = result

      # Resume: call continuation
      {result2, _env} = resume.(42, env)
      assert result2 == {:got, 42}
    end

    test "replaces default ExternalSuspend-producing Yield handler" do
      # Default Yield produces ExternalSuspend
      comp1 = Yield.yield(:test) |> Yield.with_handler()
      {result1, _env1} = Comp.call(comp1, Env.new(), &Comp.identity_k/2)
      assert %Comp.ExternalSuspend{value: :test} = result1

      # FiberYield replaces it with InternalSuspend
      comp2 = Yield.yield(:test) |> FiberYield.with_handler()
      {result2, _env2} = Comp.call(comp2, Env.new(), &Comp.identity_k/2)
      assert %InternalSuspend{payload: %InternalSuspend.FiberYield{value: :test}} = result2
    end
  end
end
