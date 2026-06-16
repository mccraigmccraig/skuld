defmodule Skuld.PageMachineTest do
  use ExUnit.Case, async: true

  alias Skuld.FiberPool.Server, as: FiberServer
  alias Skuld.Comp.Cancelled
  alias Skuld.Comp.ExternalSuspend
  alias Skuld.Comp.Throw

  defmodule TestLive do
    use Skuld.PageMachine,
      tag: :test_flow,
      on_yield: &__MODULE__.handle_yield/2,
      on_complete: &__MODULE__.handle_complete/2,
      on_error: &__MODULE__.handle_error/2,
      on_cancel: &__MODULE__.handle_cancel/2,
      on_throw: &__MODULE__.handle_throw/2

    def handle_yield(value, socket), do: {:yield, value, socket}
    def handle_complete(result, socket), do: {:complete, result, socket}
    def handle_error(reason, socket), do: {:error, reason, socket}
    def handle_cancel(reason, socket), do: {:cancel, reason, socket}
    def handle_throw(error, socket), do: {:throw, error, socket}
  end

  test "dispatches ExternalSuspend to on_yield" do
    assert {:yield, :shipping, %{step: nil}} ==
             TestLive.handle_info(
               {FiberServer, :test_flow, %ExternalSuspend{value: :shipping}},
               %{step: nil}
             )
  end

  test "dispatches {:error, reason} to on_error" do
    assert {:error, :not_found, %{}} ==
             TestLive.handle_info(
               {FiberServer, :test_flow, {:error, :not_found}},
               %{}
             )
  end

  test "dispatches Cancelled to on_cancel" do
    assert {:cancel, :user_navigated, %{}} ==
             TestLive.handle_info(
               {FiberServer, :test_flow, %Cancelled{reason: :user_navigated}},
               %{}
             )
  end

  test "dispatches Throw to on_throw" do
    assert {:throw, :boom, %{}} ==
             TestLive.handle_info(
               {FiberServer, :test_flow, %Throw{error: :boom}},
               %{}
             )
  end

  test "dispatches other values to on_complete" do
    assert {:complete, {:ok, :done}, %{}} ==
             TestLive.handle_info(
               {FiberServer, :test_flow, {:ok, :done}},
               %{}
             )
  end

  test "ignores messages with wrong tag" do
    assert_raise FunctionClauseError, fn ->
      TestLive.handle_info({FiberServer, :other_tag, :whatever}, %{})
    end
  end

  describe "optional callbacks" do
    defmodule MinimalLive do
      use Skuld.PageMachine,
        tag: :minimal,
        on_yield: fn value, socket -> {:yielded, value, socket} end
    end

    test "works with only on_yield" do
      assert {:yielded, :step, %{}} ==
               MinimalLive.handle_info(
                 {FiberServer, :minimal, %ExternalSuspend{value: :step}},
                 %{}
               )
    end

    test "raises on unmatched result when no callback given" do
      assert_raise FunctionClauseError, fn ->
        MinimalLive.handle_info({FiberServer, :minimal, :unexpected}, %{})
      end
    end
  end

  describe "def_pipe_event/2" do
    defmodule PipeEventAsyncTest do
      import Skuld.PageMachine, only: [def_pipe_event: 1]
      def_pipe_event "test_event"
    end

    test "generates handle_event/3 function" do
      assert function_exported?(PipeEventAsyncTest, :handle_event, 3)
    end

    test "generated handle_event raises KeyError when assign_key is missing" do
      assert_raise KeyError, fn ->
        PipeEventAsyncTest.handle_event("test_event", 42, %{assigns: %{}})
      end
    end
  end

  describe "def_pipe_event/2 with pattern+block" do
    defmodule PipeEventAsyncPatternTest do
      import Skuld.PageMachine, only: [def_pipe_event: 3]

      def_pipe_event "submit", %{"value" => v} do
        {:ok, v}
      end
    end

    test "generates handle_event/3 that pattern-matches params" do
      assert function_exported?(PipeEventAsyncPatternTest, :handle_event, 3)
    end

    test "clause does not match when params pattern differs" do
      assert_raise FunctionClauseError, fn ->
        PipeEventAsyncPatternTest.handle_event("submit", %{"other" => 1}, %{assigns: %{}})
      end
    end
  end
end
