defmodule Skuld.Coroutine.PageMachineTest do
  use ExUnit.Case, async: false

  alias Skuld.Coroutine.PageMachine
  alias Skuld.Effects.{Throw, Yield}

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
end
