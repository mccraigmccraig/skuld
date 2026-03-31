defmodule Skuld.Effects.Port.Adapter.EffectfulTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  # ---------------------------------------------------------------
  # Test contract and implementations
  # ---------------------------------------------------------------

  defmodule TestContract do
    use Skuld.Effects.Port.Contract

    defport(
      get_todo(tenant_id :: String.t(), id :: String.t()) ::
        {:ok, map()} | {:error, term()}
    )

    defport(
      list_todos(tenant_id :: String.t()) ::
        {:ok, [map()]} | {:error, term()}
    )

    defport(health_check() :: :ok)
  end

  # Effectful implementation — returns computations (satisfies Effectful behaviour)
  defmodule EffectfulImpl do
    @behaviour TestContract.Effectful

    def get_todo(tenant_id, id) do
      Comp.pure({:ok, %{tenant_id: tenant_id, id: id, source: :effectful}})
    end

    def list_todos(tenant_id) do
      Comp.pure({:ok, [%{tenant_id: tenant_id, id: "1"}]})
    end

    def health_check do
      Comp.pure(:ok)
    end
  end

  # Effectful adapter — bridges effectful impl to Plain interface
  defmodule TestAdapter do
    use Skuld.Effects.Port.Adapter.Effectful,
      contract: TestContract,
      impl: EffectfulImpl,
      stack: &Function.identity/1
  end

  # ---------------------------------------------------------------
  # Effectful impl that uses State effect
  # ---------------------------------------------------------------

  defmodule StatefulImpl do
    @behaviour TestContract.Effectful

    def get_todo(tenant_id, id) do
      Comp.bind(State.get(), fn count ->
        Comp.bind(State.put(count + 1), fn _ ->
          Comp.pure({:ok, %{tenant_id: tenant_id, id: id, call_count: count + 1}})
        end)
      end)
    end

    def list_todos(tenant_id) do
      Comp.bind(State.get(), fn count ->
        Comp.bind(State.put(count + 1), fn _ ->
          Comp.pure({:ok, [%{tenant_id: tenant_id, call_count: count + 1}]})
        end)
      end)
    end

    def health_check do
      Comp.pure(:ok)
    end
  end

  defmodule StatefulAdapter do
    use Skuld.Effects.Port.Adapter.Effectful,
      contract: TestContract,
      impl: StatefulImpl,
      stack: &State.with_handler(&1, 0)
  end

  # ---------------------------------------------------------------
  # Effectful impl that can throw errors
  # ---------------------------------------------------------------

  defmodule ThrowingImpl do
    @behaviour TestContract.Effectful

    def get_todo(_tenant_id, "bad_id") do
      Throw.throw(:not_found)
    end

    def get_todo(tenant_id, id) do
      Comp.pure({:ok, %{tenant_id: tenant_id, id: id}})
    end

    def list_todos(_tenant_id) do
      Throw.throw(:unauthorized)
    end

    def health_check do
      Comp.pure(:ok)
    end
  end

  defmodule ThrowingAdapter do
    use Skuld.Effects.Port.Adapter.Effectful,
      contract: TestContract,
      impl: ThrowingImpl,
      stack: &Throw.with_handler/1
  end

  # ---------------------------------------------------------------
  # Basic Effectful Adapter Tests
  # ---------------------------------------------------------------

  describe "generated module satisfies Behaviour" do
    test "adapter implements all Behaviour callbacks" do
      callbacks = TestContract.behaviour_info(:callbacks)

      for {name, arity} <- callbacks do
        assert function_exported?(TestAdapter, name, arity),
               "TestAdapter should export #{name}/#{arity}"
      end
    end

    test "adapter for stateful impl implements all Behaviour callbacks" do
      callbacks = TestContract.behaviour_info(:callbacks)

      for {name, arity} <- callbacks do
        assert function_exported?(StatefulAdapter, name, arity)
      end
    end
  end

  describe "generated functions return plain Elixir values" do
    test "multi-arg operation returns plain value" do
      result = TestAdapter.get_todo("t1", "id1")
      assert {:ok, %{tenant_id: "t1", id: "id1", source: :effectful}} = result
    end

    test "single-arg operation returns plain value" do
      result = TestAdapter.list_todos("t1")
      assert {:ok, [%{tenant_id: "t1", id: "1"}]} = result
    end

    test "zero-arg operation returns plain value" do
      result = TestAdapter.health_check()
      assert :ok = result
    end

    test "results are NOT computations (not functions)" do
      result = TestAdapter.get_todo("t1", "id1")
      refute is_function(result)

      result = TestAdapter.health_check()
      refute is_function(result)
    end
  end

  # ---------------------------------------------------------------
  # Stack Function Tests
  # ---------------------------------------------------------------

  describe "stack function is applied correctly" do
    test "stateful impl has its State effect handled by the stack" do
      result = StatefulAdapter.get_todo("t1", "id1")
      assert {:ok, %{tenant_id: "t1", id: "id1", call_count: 1}} = result
    end

    test "each call gets fresh state (stack creates new handler scope)" do
      result1 = StatefulAdapter.get_todo("t1", "id1")
      assert {:ok, %{call_count: 1}} = result1

      # Second call should also get count=1, not count=2
      result2 = StatefulAdapter.get_todo("t1", "id2")
      assert {:ok, %{call_count: 1}} = result2
    end
  end

  # ---------------------------------------------------------------
  # Error Propagation Tests
  # ---------------------------------------------------------------

  describe "errors from effectful impl propagate correctly" do
    test "Throw in impl raises when Throw handler catches it" do
      # ThrowingAdapter installs Throw.with_handler, so Throw results in
      # a %Comp.Throw{} sentinel which Comp.run! raises as ThrowError
      assert_raise Skuld.Comp.ThrowError, fn ->
        ThrowingAdapter.get_todo("t1", "bad_id")
      end
    end

    test "successful operations still work with Throw handler" do
      result = ThrowingAdapter.get_todo("t1", "good_id")
      assert {:ok, %{tenant_id: "t1", id: "good_id"}} = result
    end

    test "zero-arg operation works with Throw handler" do
      result = ThrowingAdapter.health_check()
      assert :ok = result
    end
  end

  # ---------------------------------------------------------------
  # Compile-time Validation Tests
  # ---------------------------------------------------------------

  describe "compile-time validation" do
    test "raises CompileError when contract module lacks __port_operations__" do
      assert_raise CompileError, ~r/does not appear to be a Port.Contract module/, fn ->
        Code.compile_string("""
        defmodule NotAContract do
          def some_function, do: :ok
        end

        defmodule BadEffectfulAdapter do
          use Skuld.Effects.Port.Adapter.Effectful,
            contract: NotAContract,
            impl: NotAContract,
            stack: &Function.identity/1
        end
        """)
      end
    end

    test "raises KeyError when required options are missing" do
      assert_raise KeyError, ~r/key :contract not found/, fn ->
        Code.compile_string("""
        defmodule MissingContractAdapter do
          use Skuld.Effects.Port.Adapter.Effectful,
            impl: SomeModule,
            stack: &Function.identity/1
        end
        """)
      end
    end
  end

  # ---------------------------------------------------------------
  # Integration Test: Full Round-Trip with Real Effects
  # ---------------------------------------------------------------

  describe "integration: full round-trip with real effects" do
    # A more complex effectful implementation that uses multiple effects
    defmodule CountingImpl do
      @behaviour TestContract.Effectful

      def get_todo(tenant_id, id) do
        Comp.bind(State.get(), fn calls ->
          Comp.bind(State.put([{:get_todo, tenant_id, id} | calls]), fn _ ->
            Comp.pure({:ok, %{tenant_id: tenant_id, id: id, source: :counting}})
          end)
        end)
      end

      def list_todos(tenant_id) do
        Comp.bind(State.get(), fn calls ->
          Comp.bind(State.put([{:list_todos, tenant_id} | calls]), fn _ ->
            Comp.pure({:ok, [%{tenant_id: tenant_id, source: :counting}]})
          end)
        end)
      end

      def health_check do
        Comp.pure(:ok)
      end
    end

    defmodule CountingAdapter do
      use Skuld.Effects.Port.Adapter.Effectful,
        contract: TestContract,
        impl: CountingImpl,
        stack: &State.with_handler(&1, [])
    end

    test "effectful impl with State is correctly run through stack" do
      result = CountingAdapter.get_todo("t1", "id1")
      assert {:ok, %{tenant_id: "t1", id: "id1", source: :counting}} = result
    end

    test "list operation works through stack" do
      result = CountingAdapter.list_todos("t1")
      assert {:ok, [%{tenant_id: "t1", source: :counting}]} = result
    end

    test "zero-arg operation works through stack" do
      result = CountingAdapter.health_check()
      assert :ok = result
    end
  end

  # ---------------------------------------------------------------
  # Multi-Stack Integration
  # ---------------------------------------------------------------

  describe "integration: multi-effect stack" do
    # Effectful impl that uses both State and Throw
    defmodule MultiEffectImpl do
      @behaviour TestContract.Effectful

      def get_todo(tenant_id, "fail") do
        Throw.throw({:not_found, tenant_id})
      end

      def get_todo(tenant_id, id) do
        Comp.bind(State.modify(fn count -> count + 1 end), fn old_count ->
          Comp.pure({:ok, %{tenant_id: tenant_id, id: id, call: old_count + 1}})
        end)
      end

      def list_todos(_tenant_id) do
        Comp.pure({:ok, []})
      end

      def health_check do
        Comp.pure(:ok)
      end
    end

    defmodule MultiEffectAdapter do
      use Skuld.Effects.Port.Adapter.Effectful,
        contract: TestContract,
        impl: MultiEffectImpl,
        stack: fn comp ->
          comp
          |> State.with_handler(0)
          |> Throw.with_handler()
        end
    end

    test "success path with multiple effects" do
      result = MultiEffectAdapter.get_todo("t1", "id1")
      assert {:ok, %{tenant_id: "t1", id: "id1", call: 1}} = result
    end

    test "throw path raises through Comp.run!" do
      assert_raise Skuld.Comp.ThrowError, fn ->
        MultiEffectAdapter.get_todo("t1", "fail")
      end
    end

    test "zero-arg still works with multi-effect stack" do
      assert :ok = MultiEffectAdapter.health_check()
    end
  end
end
