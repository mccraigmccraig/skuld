defmodule Skuld.PageMachine.ProtocolTest do
  use ExUnit.Case, async: true

  alias Skuld.FiberPool.Server, as: FiberServer
  alias Skuld.Comp.ExternalSuspend

  defmodule StoreProtocol do
    use Skuld.PageMachine.Contract

    defspindle Products do
      defevent("search", SearchEvent, params: [query: String.t()])
      defevent("filter", FilterEvent, params: [filters: map()])
      defevent("buy")

      defyield(:browsing)
      defnotify(results(products: [map()], total: integer()))
    end

    defspindle Checkout do
      defevent("submit_shipping", ShippingEvent, params: [shipping: map()])
      defevent("submit_payment", PaymentEvent, params: [payment: map()])

      defyield(:shipping)
      defyield(payment(method: String.t()))
    end
  end

  defmodule ProtocolLive2 do
    use Skuld.PageMachine,
      protocol: StoreProtocol,
      on_yield: &__MODULE__.handle_yield/2,
      on_error: &__MODULE__.handle_error/2

    def handle_yield(value, socket), do: {:yielded, value, socket}
    def handle_error(reason, socket), do: {:error, reason, socket}
  end

  describe "protocol-based PageMachine" do
    test "auto-generates handle_event for each protocol event" do
      assert function_exported?(ProtocolLive2, :handle_event, 3)
    end

    test "handle_info dispatches yields with default tag" do
      result =
        ProtocolLive2.handle_info(
          {FiberServer, Skuld.PageMachine.Default, %ExternalSuspend{value: :browsing}},
          %{}
        )

      assert {:yielded, :browsing, %{}} = result
    end

    test "yield struct matches protocol definition" do
      struct = %StoreProtocol.Products.Notify.Results{products: [], total: 0}
      assert struct.products == []
      assert struct.total == 0
    end

    test "Yield sub-module function produces a computation" do
      comp = StoreProtocol.Products.Yield.browsing()
      assert is_function(comp, 2)
    end

    test "Notify sub-module function produces a computation" do
      comp = StoreProtocol.Products.Notify.results(products: [], total: 1)

      assert is_function(comp, 2)
    end

    test "event struct generated for event with struct name" do
      assert Code.ensure_loaded?(StoreProtocol.Products.SearchEvent)
      assert Code.ensure_loaded?(StoreProtocol.Checkout.ShippingEvent)
    end

    test "Yield sub-module loaded" do
      assert Code.ensure_loaded?(StoreProtocol.Products.Yield)
      assert Code.ensure_loaded?(StoreProtocol.Checkout.Yield)
    end

    test "Notify sub-module loaded" do
      assert Code.ensure_loaded?(StoreProtocol.Products.Notify)
    end
  end

  describe "multi-spindle dispatch with protocol" do
    defmodule MultiSpindleProtocolLive do
      @moduledoc false

      def handle_yield(StoreProtocol.Products, value, socket), do: {:products, value, socket}
      def handle_yield(StoreProtocol.Checkout, value, socket), do: {:checkout, value, socket}
    end

    defmodule MultiSpindlePM do
      use Skuld.PageMachine,
        protocol: StoreProtocol,
        on_yield: &MultiSpindleProtocolLive.handle_yield/3
    end

    test "dispatches products yield to correct callback" do
      result =
        MultiSpindlePM.handle_info(
          {FiberServer, StoreProtocol.Products, %ExternalSuspend{value: :browsing}},
          %{assigns: %{}}
        )

      assert {:products, :browsing, %{assigns: %{}}} = result
    end

    test "dispatches checkout yield to correct callback" do
      result =
        MultiSpindlePM.handle_info(
          {FiberServer, StoreProtocol.Checkout, %ExternalSuspend{value: :shipping}},
          %{assigns: %{}}
        )

      assert {:checkout, :shipping, %{assigns: %{}}} = result
    end

    test "handle_event wraps params in event struct for event with struct name" do
      result =
        MultiSpindlePM.handle_event(
          "search",
          %{"query" => "widget"},
          %{assigns: %{Skuld.PageMachine.DefaultAssign => self()}}
        )

      assert {:noreply, _socket} = result

      assert_received {:fiber_resume, StoreProtocol.Products,
                       %StoreProtocol.Products.SearchEvent{query: "widget"}}
    end
  end
end
