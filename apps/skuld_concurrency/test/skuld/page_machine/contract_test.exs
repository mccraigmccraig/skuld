defmodule Skuld.PageMachine.ContractTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.Yield

  defmodule TestProtocol do
    use Skuld.PageMachine.Contract

    defevent("search", into: :products, params: [query: String.t()])
    defevent("filter", into: :products)
    defevent("buy", into: :products)

    defyield(:products, :browsing)
    defyield(:products, :results, params: [products: [map()], total: integer()])
    defyield(:checkout, :shipping)
    defyield(:checkout, :payment, params: [method: String.t()])
  end

  describe "defevent declarations" do
    test "__protocol_events__/0 returns all event metadata" do
      events = TestProtocol.__protocol_events__()

      assert length(events) == 3
      assert Enum.any?(events, fn e -> e.event == "search" and e.into == :products end)
      assert Enum.any?(events, fn e -> e.event == "filter" and e.into == :products end)
      assert Enum.any?(events, fn e -> e.event == "buy" and e.into == :products end)
    end

    test "event with params includes param metadata" do
      search = Enum.find(TestProtocol.__protocol_events__(), &(&1.event == "search"))
      assert match?({:query, _}, Enum.at(search.params, 0))
    end

    test "event without params has empty params list" do
      filter = Enum.find(TestProtocol.__protocol_events__(), &(&1.event == "filter"))
      assert filter.params == []
    end

    test "__pm_events__/0 returns event tuples" do
      entries = TestProtocol.__pm_events__()

      assert length(entries) == 3

      search = Enum.find(entries, fn {event, _spindle, _params} -> event == "search" end)
      assert {"search", :products, params} = search
      assert is_list(params)

      filter = Enum.find(entries, fn {event, _spindle, _params} -> event == "filter" end)
      assert {"filter", :products, []} = filter

      buy = Enum.find(entries, fn {event, _spindle, _params} -> event == "buy" end)
      assert {"buy", :products, []} = buy
    end
  end

  describe "defyield declarations" do
    test "__protocol_yields__/0 returns all yield metadata" do
      yields = TestProtocol.__protocol_yields__()

      assert length(yields) == 4
      assert Enum.any?(yields, fn y -> y.spindle == :products and y.tag == :browsing end)
      assert Enum.any?(yields, fn y -> y.spindle == :products and y.tag == :results end)
      assert Enum.any?(yields, fn y -> y.spindle == :checkout and y.tag == :shipping end)
      assert Enum.any?(yields, fn y -> y.spindle == :checkout and y.tag == :payment end)
    end

    test "yield without params has empty params list" do
      browsing = Enum.find(TestProtocol.__protocol_yields__(), &(&1.tag == :browsing))
      assert browsing.params == []
    end

    test "yield with params includes param metadata" do
      results = Enum.find(TestProtocol.__protocol_yields__(), &(&1.tag == :results))
      assert length(results.params) == 2
      assert {:products, _products_type} = Enum.at(results.params, 0)
      assert {:total, _total_type} = Enum.at(results.params, 1)
    end
  end

  describe "typed yield structs" do
    test "generates struct module for yield with params" do
      assert Code.ensure_loaded?(TestProtocol.ProductsResults)

      struct = %TestProtocol.ProductsResults{}
      assert struct.products == nil
      assert struct.total == nil
    end

    test "does not generate struct module for yield without params" do
      refute Code.ensure_loaded?(TestProtocol.ProductsBrowsing)
      refute Code.ensure_loaded?(TestProtocol.CheckoutShipping)
    end

    test "yield/3 builds typed struct and calls Yield.yield" do
      comp =
        TestProtocol.yield(:products, :results, %{
          products: [%{name: "Widget"}],
          total: 42
        })
        |> Yield.with_handler()

      {result, _env} = Skuld.Comp.run(comp)

      assert %Skuld.Comp.ExternalSuspend{value: struct} = result
      assert %TestProtocol.ProductsResults{} = struct
      assert struct.products == [%{name: "Widget"}]
      assert struct.total == 42
    end

    test "yield/3 raises for yield without params" do
      assert_raise ArgumentError, fn ->
        TestProtocol.yield(:products, :browsing, %{})
      end
    end
  end

  describe "validation" do
    test "compile error for module with no defevent declarations" do
      error =
        assert_raise CompileError, fn ->
          defmodule NoEventsProtocol do
            use Skuld.PageMachine.Contract

            defyield(:products, :browsing)
          end
        end

      assert error.description =~ "no defevent declarations"
    end

    test "compile error for module with no defyield declarations" do
      error =
        assert_raise CompileError, fn ->
          defmodule NoYieldsProtocol do
            use Skuld.PageMachine.Contract

            defevent("search", into: :products)
          end
        end

      assert error.description =~ "no defyield declarations"
    end

    test "compile error for duplicate event names" do
      error =
        assert_raise CompileError, fn ->
          defmodule DupEventProtocol do
            use Skuld.PageMachine.Contract

            defevent("search", into: :products)
            defevent("search", into: :checkout)

            defyield(:products, :browsing)
            defyield(:checkout, :shipping)
          end
        end

      assert error.description =~ "Duplicate event names"
    end

    test "compile error for duplicate spindle/tag pairs in yield" do
      error =
        assert_raise CompileError, fn ->
          defmodule DupYieldProtocol do
            use Skuld.PageMachine.Contract

            defevent("search", into: :products)

            defyield(:products, :browsing)
            defyield(:products, :browsing)
          end
        end

      assert error.description =~ "Duplicate spindle/tag pairs"
    end
  end
end
