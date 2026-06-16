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
      defyield(results(products: [map()], total: integer()))

      defnotify(purchase_selected(product: map()))
    end

    defspindle Checkout do
      defevent("submit_shipping", ShippingEvent, params: [shipping: map()])
      defevent("submit_payment", PaymentEvent, params: [payment: map()])

      defyield(:shipping)
      defyield(payment(method: String.t()))
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

      assert length(yields) == 5

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

    test "yield has nest flag" do
      browsing = Enum.find(TestProtocol.__protocol_yields__(), &(&1.tag == :browsing))
      assert browsing.nest == :yield

      purchase = Enum.find(TestProtocol.__protocol_yields__(), &(&1.tag == :purchase_selected))
      assert purchase.nest == :notify
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
    test "generates Products.Yield module" do
      assert Code.ensure_loaded?(TestProtocol.Products.Yield)
    end

    test "generates Products.Notify module" do
      assert Code.ensure_loaded?(TestProtocol.Products.Notify)
    end

    test "generates Checkout.Yield module" do
      assert Code.ensure_loaded?(TestProtocol.Checkout.Yield)
    end

    test "0-arity yield generates function on Yield sub-module" do
      comp = TestProtocol.Products.Yield.browsing() |> Yield.with_handler()
      {result, _env} = Skuld.Comp.run(comp)

      assert %Skuld.Comp.ExternalSuspend{value: %TestProtocol.Products.Yield.Browsing{}} = result
    end

    test "keyword-arg yield generates function on Yield sub-module" do
      comp =
        TestProtocol.Products.Yield.results(products: [%{name: "Widget"}], total: 42)
        |> Yield.with_handler()

      {result, _env} = Skuld.Comp.run(comp)

      assert %Skuld.Comp.ExternalSuspend{value: struct} = result
      assert %TestProtocol.Products.Yield.Results{} = struct
      assert struct.products == [%{name: "Widget"}]
      assert struct.total == 42
    end

    test "0-arity yield on Checkout" do
      comp = TestProtocol.Checkout.Yield.shipping() |> Yield.with_handler()
      {result, _env} = Skuld.Comp.run(comp)

      assert %Skuld.Comp.ExternalSuspend{value: %TestProtocol.Checkout.Yield.Shipping{}} = result
    end

    test "single-param yield function" do
      comp =
        TestProtocol.Checkout.Yield.payment(method: "card")
        |> Yield.with_handler()

      {result, _env} = Skuld.Comp.run(comp)

      assert %Skuld.Comp.ExternalSuspend{
               value: %TestProtocol.Checkout.Yield.Payment{method: "card"}
             } = result
    end
  end

  describe "defnotify" do
    test "generates function on Notify sub-module" do
      comp =
        TestProtocol.Products.Notify.purchase_selected(product: %{name: "X"})
        |> Skuld.Effects.FiberYield.with_handler()
        |> Skuld.Comp.call(Skuld.Comp.Env.new(), &Skuld.Comp.identity_k/2)

      {result, _env} = comp

      assert %Skuld.Comp.InternalSuspend{
               payload: %Skuld.Comp.InternalSuspend.FiberYield{value: struct, notify: true}
             } = result

      assert %TestProtocol.Products.Notify.PurchaseSelected{product: %{name: "X"}} = struct
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
