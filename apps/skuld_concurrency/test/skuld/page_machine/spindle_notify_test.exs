defmodule Skuld.PageMachine.SpindleNotifyTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Effects.FiberYield
  alias Skuld.PageMachine.Spindle

  describe "Spindle.notify/1" do
    test "produces InternalSuspend with FiberYield notify: true" do
      {result, _env} =
        comp do
          _ <- Spindle.notify(:checkpoint)
          :done
        end
        |> FiberYield.with_handler()
        |> Comp.call(Env.new(), &Comp.identity_k/2)

      assert %InternalSuspend{
               payload: %InternalSuspend.FiberYield{value: :checkpoint, notify: true}
             } = result
    end

    test "resume callback returns the continuation result with nil input" do
      {suspend, env} =
        comp do
          _ <- Spindle.notify(:checkpoint)
          {:ok, 42}
        end
        |> FiberYield.with_handler()
        |> Comp.call(Env.new(), &Comp.identity_k/2)

      {resumed, _final_env} = suspend.resume.(nil, env)

      assert {:ok, 42} = resumed
    end

    test "multiple notifies in sequence produce multiple FiberYields" do
      {first, env1} =
        comp do
          _ <- Spindle.notify(:first)
          _ <- Spindle.notify(:second)
          :done
        end
        |> FiberYield.with_handler()
        |> Comp.call(Env.new(), &Comp.identity_k/2)

      assert %InternalSuspend{
               payload: %InternalSuspend.FiberYield{value: :first, notify: true}
             } = first

      {second, _env2} = first.resume.(nil, env1)

      assert %InternalSuspend{
               payload: %InternalSuspend.FiberYield{value: :second, notify: true}
             } = second
    end
  end
end
