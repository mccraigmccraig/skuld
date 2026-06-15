defmodule Skuld.FiberPool.ServerTest do
  use ExUnit.Case, async: true
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Yield
  alias Skuld.FiberPool.Server

  defmodule TestFlows do
    use Skuld.Syntax

    defcomp one_yield do
      a <- Yield.yield(:ask)
      {:got, a}
    end

    defcomp two_yields do
      a <- Yield.yield(:first)
      b <- Yield.yield(:second)
      {a, b}
    end

    defcomp immediate do
      42
    end
  end

  describe "start_link/1" do
    test "starts a server and receives yield message" do
      {:ok, server} = Server.start_link(main: TestFlows.one_yield())

      assert_receive {Server, :main, %Comp.ExternalSuspend{value: :ask}}
      assert Process.alive?(server)
    end

    test "resume continues the fiber" do
      {:ok, server} = Server.start_link(main: TestFlows.one_yield())

      assert_receive {Server, :main, %Comp.ExternalSuspend{value: :ask}}
      Server.resume(server, :main, 99)

      assert_receive {Server, :main, {:got, 99}}
      assert_receive {Server, :all_done, []}
      refute Process.alive?(server)
    end

    test "multiple yields work" do
      {:ok, server} = Server.start_link(main: TestFlows.two_yields())

      assert_receive {Server, :main, %Comp.ExternalSuspend{value: :first}}
      Server.resume(server, :main, :a)

      assert_receive {Server, :main, %Comp.ExternalSuspend{value: :second}}
      Server.resume(server, :main, :b)

      assert_receive {Server, :main, {:a, :b}}
      assert_receive {Server, :all_done, []}
      refute Process.alive?(server)
    end

    test "immediate completion sends result" do
      {:ok, server} = Server.start_link(main: TestFlows.immediate())

      assert_receive {Server, :main, 42}
      assert_receive {Server, :all_done, []}
      refute Process.alive?(server)
    end
  end
end
