defmodule Skuld.PageMachine.ContractTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.Yield

  defmodule TestProtocol do
    use Skuld.PageMachine.Contract

    defspindle Products do
      defevent("search", SearchEvent, params: [query: String.t()])
      defevent("filter", FilterEvent, params: [filters: map()])
      defevent("buy")

      defyield(:browsing)
      defyield(:results, params: [products: [map()], total: integer()])
    end

    defspindle Checkout do
      defevent("submit_shipping", ShippingEvent, params: [shipping: map()])
      defevent("submit_payment", PaymentEvent, params: [payment: map()])

      defyield(:shipping)
      defyield(:payment, params: [method: String.t()])
    end
  end

  describe "defevent declarations" do
    test "__protocol_events__/0 returns all event metadata" do
      events = TestProtocol.__protocol_events__()

      assert length(events) == 5

      search = Enum.find(events, &(&1.event == "search"))
      assert search.spindle == TestProtocol.Products
      assert search.struct_name == :SearchEvent

      buy = Enum.find(events, &(&1.event == "buy"))
      assert buy.struct_name == nil
      assert buy.params == []
    end

    test "event with params and struct name records both" do
      search = Enum.find(TestProtocol.__protocol_events__(), &(&1.event == "search"))
      assert length(search.params) == 1
    end

    test "__pm_events__/0 returns tuples with struct_name" do
      entries = TestProtocol.__pm_events__()
      assert length(entries) == 5

      search = Enum.find(entries, fn {event, _spindle, _sn, _params} -> event == "search" end)
      assert {"search", TestProtocol.Products, :SearchEvent, params} = search
      assert is_list(params)

      buy = Enum.find(entries, fn {event, _spindle, _sn, _params} -> event == "buy" end)
      assert {"buy", TestProtocol.Products, nil, []} = buy
    end
  end

  describe "defyield declarations" do
    test "__protocol_yields__/0 returns all yield metadata" do
      yields = TestProtocol.__protocol_yields__()

      assert length(yields) == 4

      assert Enum.any?(yields, fn y ->
               y.spindle == TestProtocol.Products and y.tag == :browsing
             end)

      assert Enum.any?(yields, fn y ->
               y.spindle == TestProtocol.Products and y.tag == :results
             end)

      assert Enum.any?(yields, fn y ->
               y.spindle == TestProtocol.Checkout and y.tag == :shipping
             end)

      assert Enum.any?(yields, fn y ->
               y.spindle == TestProtocol.Checkout and y.tag == :payment
             end)
    end

    test "yield without params has empty params list" do
      browsing = Enum.find(TestProtocol.__protocol_yields__(), &(&1.tag == :browsing))
      assert browsing.params == []
    end

    test "yield with params includes param metadata" do
      results = Enum.find(TestProtocol.__protocol_yields__(), &(&1.tag == :results))
      assert length(results.params) == 2
    end
  end

  describe "event struct generation" do
    test "generates event struct module for event with struct name" do
      assert Code.ensure_loaded?(TestProtocol.Products.SearchEvent)

      struct = %TestProtocol.Products.SearchEvent{}
      assert struct.query == nil
    end

    test "generates multiple event structs in same spindle" do
      assert Code.ensure_loaded?(TestProtocol.Products.FilterEvent)
    end

    test "generates event structs in different spindles" do
      assert Code.ensure_loaded?(TestProtocol.Checkout.ShippingEvent)
      assert Code.ensure_loaded?(TestProtocol.Checkout.PaymentEvent)
    end

    test "does not generate struct for event without struct name" do
      refute Code.ensure_loaded?(TestProtocol.Products.Buy)
    end

    test "event struct fields match params" do
      struct = %TestProtocol.Checkout.ShippingEvent{shipping: %{street: "123 Main"}}
      assert struct.shipping.street == "123 Main"
    end
  end

  describe "spindle modules" do
    test "generates Products spindle module" do
      assert Code.ensure_loaded?(TestProtocol.Products)
    end

    test "generates Checkout spindle module" do
      assert Code.ensure_loaded?(TestProtocol.Checkout)
    end

    test "generates 0-arity yield function for tag without params" do
      comp = TestProtocol.Products.browsing() |> Yield.with_handler()
      {result, _env} = Skuld.Comp.run(comp)
      assert %Skuld.Comp.ExternalSuspend{value: :browsing} = result
    end

    test "generates keyword-arg yield function with typed struct for tag with params" do
      comp =
        TestProtocol.Products.results(products: [%{name: "Widget"}], total: 42)
        |> Yield.with_handler()

      {result, _env} = Skuld.Comp.run(comp)

      assert %Skuld.Comp.ExternalSuspend{value: struct} = result
      assert %TestProtocol.Products.Results{} = struct
      assert struct.products == [%{name: "Widget"}]
      assert struct.total == 42
    end

    test "generates single-param yield function" do
      comp =
        TestProtocol.Checkout.payment(method: "card")
        |> Yield.with_handler()

      {result, _env} = Skuld.Comp.run(comp)

      assert %Skuld.Comp.ExternalSuspend{value: %TestProtocol.Checkout.Payment{method: "card"}} =
               result
    end
  end

  describe "validation" do
    test "compile error for module with no defevent declarations" do
      error =
        assert_raise CompileError, fn ->
          defmodule NoEventsProtocol do
            use Skuld.PageMachine.Contract

            defspindle Products do
              defyield(:browsing)
            end
          end
        end

      assert error.description =~ "no defevent declarations"
    end

    test "compile error for module with no defyield declarations" do
      error =
        assert_raise CompileError, fn ->
          defmodule NoYieldsProtocol do
            use Skuld.PageMachine.Contract

            defspindle Products do
              defevent("search")
            end
          end
        end

      assert error.description =~ "no defyield declarations"
    end

    test "compile error for duplicate event names" do
      error =
        assert_raise CompileError, fn ->
          defmodule DupEventProtocol do
            use Skuld.PageMachine.Contract

            defspindle Products do
              defevent("search")
            end

            defspindle Checkout do
              defevent("search")
              defyield(:shipping)
            end
          end
        end

      assert error.description =~ "Duplicate event names"
    end

    test "compile error for duplicate spindle/tag pairs" do
      error =
        assert_raise CompileError, fn ->
          defmodule DupYieldProtocol do
            use Skuld.PageMachine.Contract

            defspindle Products do
              defevent("search")
              defyield(:browsing)
              defyield(:browsing)
            end
          end
        end

      assert error.description =~ "Duplicate spindle/tag pairs"
    end
  end
end
