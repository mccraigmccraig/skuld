defmodule Skuld.PageMachine.ProtocolTest do
  use ExUnit.Case, async: true

  alias Skuld.FiberPool.Server, as: FiberServer
  alias Skuld.Comp.ExternalSuspend

  defmodule StoreProtocol do
    use Skuld.PageMachine.Contract

    defevent("search", into: :products, params: [query: String.t()])
    defevent("filter", into: :products)
    defevent("submit_shipping", into: :checkout, params: [shipping: map()])

    defyield(:products, :browsing)
    defyield(:products, :results, params: [products: [map()], total: integer()])
    defyield(:checkout, :shipping)
    defyield(:checkout, :payment, params: [method: String.t()])
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
      struct = %StoreProtocol.Products.Results{products: [], total: 0}
      assert struct.products == []
      assert struct.total == 0
    end

    test "spindle module yield function produces a computation" do
      comp = StoreProtocol.Products.results(products: [], total: 1)
      assert is_function(comp, 2)
    end

    test "spindle module yield for tag without params produces a computation" do
      comp = StoreProtocol.Products.browsing()
      assert is_function(comp, 2)
    end
  end

  describe "multi-spindle dispatch with protocol" do
    defmodule MultiSpindleProtocolLive do
      @moduledoc false

      def handle_yield(:products, value, socket), do: {:products, value, socket}
      def handle_yield(:checkout, value, socket), do: {:checkout, value, socket}
    end

    defmodule MultiSpindlePM do
      use Skuld.PageMachine,
        protocol: StoreProtocol,
        on_yield: &MultiSpindleProtocolLive.handle_yield/3
    end

    test "dispatches products yield to correct callback" do
      result =
        MultiSpindlePM.handle_info(
          {FiberServer, :products, %ExternalSuspend{value: :browsing}},
          %{assigns: %{}}
        )

      assert {:products, :browsing, %{assigns: %{}}} = result
    end

    test "dispatches checkout yield to correct callback" do
      result =
        MultiSpindlePM.handle_info(
          {FiberServer, :checkout, %ExternalSuspend{value: :shipping}},
          %{assigns: %{}}
        )

      assert {:checkout, :shipping, %{assigns: %{}}} = result
    end
  end
end
