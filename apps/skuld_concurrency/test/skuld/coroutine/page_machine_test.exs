defmodule Skuld.Coroutine.PageMachineTest do
  use ExUnit.Case, async: false

  alias Skuld.Coroutine.PageMachine
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield

  defmodule TestFlow do
    use Skuld.Syntax

    defcomp flow(arg) do
      a <- Yield.yield(:first)
      b <- Yield.yield(:second)
      {:ok, {arg, a, b}}
    end
  end

  defmodule ImmediateFlow do
    use Skuld.Syntax
    defcomp(flow, do: 42)
  end

  defmodule BrokenFlow do
    use Skuld.Syntax

    defcomp flow(arg) do
      _ <- Yield.yield(:start)
      {:ok, _} <- Throw.throw(:boom)
      {:ok, arg}
    end
  end

  defp fake_socket, do: %{assigns: %{}}

  defp comp do
    TestFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()
  end

  describe "run/3" do
    test "yields through on_yield" do
      result =
        PageMachine.run(comp(), fake_socket(), :test,
          on_yield: fn value, socket ->
            assert value in [:first, :second]
            {:noreply, socket}
          end,
          on_complete: fn _, s -> {:noreply, s} end
        )

      assert {:noreply, %{assigns: %{test: %PageMachine{}}}} = result
    end

    test "completes through on_complete" do
      result =
        PageMachine.run(ImmediateFlow.flow(), fake_socket(), :test,
          on_yield: fn _, s -> {:noreply, s} end,
          on_complete: fn result, socket ->
            assert result == 42
            {:noreply, socket}
          end
        )

      assert {:noreply, _} = result
    end

    test "errors through on_error" do
      comp = BrokenFlow.flow(:hello) |> Yield.with_handler() |> Throw.with_handler()

      {:noreply, socket} =
        PageMachine.run(comp, fake_socket(), :test,
          on_yield: fn _, s -> {:noreply, s} end,
          on_error: fn error, socket ->
            assert error == :boom
            {:noreply, socket}
          end
        )

      {:noreply, _} = PageMachine.run(socket.assigns.test, :go, socket)
    end

    test "missing on_yield raises" do
      assert_raise KeyError, fn ->
        PageMachine.run(comp(), fake_socket(), :test, on_error: fn _, s -> {:noreply, s} end)
      end
    end
  end

  describe "run/3 resume" do
    test "resumes through full flow" do
      {:noreply, socket} =
        PageMachine.run(comp(), fake_socket(), :test,
          on_yield: fn _, s -> {:noreply, s} end,
          on_complete: fn result, socket ->
            assert {:ok, {:hello, 10, 20}} == result
            {:noreply, socket}
          end
        )

      {:noreply, socket} = PageMachine.run(socket.assigns.test, 10, socket)
      {:noreply, _} = PageMachine.run(socket.assigns.test, 20, socket)
    end
  end

  describe "cancel/1" do
    test "dispatches through on_cancel" do
      {:noreply, socket} =
        PageMachine.run(comp(), fake_socket(), :test,
          on_yield: fn _, s -> {:noreply, s} end,
          on_cancel: fn reason, socket ->
            assert reason == :cancelled
            {:noreply, socket}
          end
        )

      {:noreply, _} = PageMachine.cancel(socket.assigns.test, socket)
    end

    test "no on_cancel is graceful" do
      {:noreply, socket} =
        PageMachine.run(comp(), fake_socket(), :test, on_yield: fn _, s -> {:noreply, s} end)

      assert {:noreply, _} = PageMachine.cancel(socket.assigns.test, socket)
    end
  end

  describe "def_pipe_event/2" do
    defmodule PipeEventTest do
      import Skuld.Coroutine.PageMachine, only: [def_pipe_event: 2]
      def_pipe_event("test_event", :runner)
    end

    test "generates handle_event/3 function" do
      assert function_exported?(PipeEventTest, :handle_event, 3)
    end

    test "generated handle_event wraps params in {event, params} and calls PageMachine.run" do
      {:noreply, socket} =
        PageMachine.run(comp(), fake_socket(), :runner,
          on_yield: fn _, s -> {:noreply, s} end,
          on_complete: fn _, s -> {:noreply, s} end
        )

      {:noreply, socket} = PipeEventTest.handle_event("test_event", 42, socket)
      assert %PageMachine{} = socket.assigns.runner
    end

    test "generated handle_event raises KeyError when assign_key is missing" do
      assert_raise KeyError, fn ->
        PipeEventTest.handle_event("test_event", 42, fake_socket())
      end
    end
  end

  describe "def_pipe_event/2 with :before" do
    defmodule PipeEventBeforeTest do
      import Skuld.Coroutine.PageMachine, only: [def_pipe_event: 3]

      def_pipe_event("test_event", :runner, before: &__MODULE__.spinner/1)

      def spinner(socket), do: put_in(socket.assigns[:loading], true)
    end

    test "calls :before callback before piping to PageMachine" do
      {:noreply, socket} =
        PageMachine.run(comp(), fake_socket(), :runner,
          on_yield: fn _, s -> {:noreply, s} end,
          on_complete: fn _, s -> {:noreply, s} end
        )

      {:noreply, socket} = PipeEventBeforeTest.handle_event("test_event", 42, socket)
      assert socket.assigns.loading == true
    end
  end

  describe "def_pipe_event/2 with pattern+block" do
    defmodule PipeEventPatternTest do
      import Skuld.Coroutine.PageMachine, only: [def_pipe_event: 4]

      def_pipe_event "submit", :runner, %{"value" => v} do
        {:ok, v}
      end
    end

    test "generates handle_event/3 that pattern-matches params and transforms via block" do
      {:noreply, socket} =
        PageMachine.run(comp(), fake_socket(), :runner,
          on_yield: fn _, s -> {:noreply, s} end,
          on_complete: fn _, s -> {:noreply, s} end
        )

      {:noreply, _} =
        PipeEventPatternTest.handle_event("submit", %{"value" => 99}, socket)
    end

    test "clause does not match when params pattern differs" do
      assert_raise FunctionClauseError, fn ->
        PipeEventPatternTest.handle_event("submit", %{"other" => 1}, fake_socket())
      end
    end
  end
end
