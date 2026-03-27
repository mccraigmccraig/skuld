defmodule Skuld.Effects.Port.Adapter.DirectTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.Port

  # ---------------------------------------------------------------
  # Test contract (same shape as effectful_test)
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

  # Plain implementation satisfying Plain behaviour
  defmodule TestImpl do
    @behaviour TestContract.Plain

    @impl true
    def get_todo(tenant_id, id) do
      {:ok, %{tenant_id: tenant_id, id: id, source: :direct_impl}}
    end

    @impl true
    def list_todos(tenant_id) do
      {:ok, [%{tenant_id: tenant_id, id: "1"}]}
    end

    @impl true
    def health_check do
      :ok
    end
  end

  # Direct adapter — delegates to TestImpl
  defmodule TestAdapter do
    use Skuld.Effects.Port.Adapter.Direct,
      contract: TestContract,
      impl: TestImpl
  end

  # Alternative implementation for swap testing
  defmodule AltImpl do
    @behaviour TestContract.Plain

    @impl true
    def get_todo(_tenant_id, _id), do: {:ok, %{source: :alt_impl}}

    @impl true
    def list_todos(_tenant_id), do: {:ok, []}

    @impl true
    def health_check, do: :ok
  end

  defmodule AltAdapter do
    use Skuld.Effects.Port.Adapter.Direct,
      contract: TestContract,
      impl: AltImpl
  end

  # ---------------------------------------------------------------
  # Basic Adapter Tests
  # ---------------------------------------------------------------

  describe "generated module satisfies Plain behaviour" do
    test "adapter implements all Plain callbacks" do
      callbacks = TestContract.Plain.behaviour_info(:callbacks)

      for {name, arity} <- callbacks do
        assert function_exported?(TestAdapter, name, arity),
               "TestAdapter should export #{name}/#{arity}"
      end
    end
  end

  describe "delegation" do
    test "delegates multi-param operation" do
      assert {:ok, %{tenant_id: "t1", id: "42", source: :direct_impl}} =
               TestAdapter.get_todo("t1", "42")
    end

    test "delegates single-param operation" do
      assert {:ok, [%{tenant_id: "t1", id: "1"}]} =
               TestAdapter.list_todos("t1")
    end

    test "delegates zero-param operation" do
      assert :ok = TestAdapter.health_check()
    end

    test "returns plain values, not computations" do
      result = TestAdapter.get_todo("t1", "42")
      # Should be a plain tuple, not a function (computation)
      assert is_tuple(result)
      refute is_function(result)
    end
  end

  describe "implementation swapping" do
    test "different adapter delegates to different impl" do
      assert {:ok, %{source: :direct_impl}} = TestAdapter.get_todo("t1", "42")
      assert {:ok, %{source: :alt_impl}} = AltAdapter.get_todo("t1", "42")
    end
  end

  describe "adapter as Port.with_handler target" do
    test "adapter can be used as a handler target for Skuld consumers" do
      # Since the adapter satisfies Plain behaviour, it can be used
      # with Port.with_handler just like any other Plain impl
      alias Skuld.Comp
      alias Skuld.Effects.Throw

      comp =
        TestContract.get_todo!("t1", "42")
        |> Port.with_handler(%{TestContract => TestAdapter})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{tenant_id: "t1", id: "42", source: :direct_impl} = result
    end
  end

  describe "compile-time validation" do
    test "raises when contract lacks __port_operations__" do
      assert_raise CompileError, ~r/does not appear to be a Port.Contract module/, fn ->
        defmodule BadDirectAdapter do
          use Skuld.Effects.Port.Adapter.Direct,
            contract: String,
            impl: TestImpl
        end
      end
    end

    test "raises when required options missing" do
      assert_raise KeyError, ~r/contract/, fn ->
        defmodule NoContractAdapter do
          use Skuld.Effects.Port.Adapter.Direct,
            impl: TestImpl
        end
      end

      assert_raise KeyError, ~r/impl/, fn ->
        defmodule NoImplAdapter do
          use Skuld.Effects.Port.Adapter.Direct,
            contract: TestContract
        end
      end
    end
  end

  describe "error propagation" do
    defmodule ErrorImpl do
      @behaviour TestContract.Plain

      @impl true
      def get_todo(_tenant_id, _id), do: {:error, :not_found}

      @impl true
      def list_todos(_tenant_id), do: {:error, :db_unavailable}

      @impl true
      def health_check, do: :ok
    end

    defmodule ErrorAdapter do
      use Skuld.Effects.Port.Adapter.Direct,
        contract: TestContract,
        impl: ErrorImpl
    end

    test "error tuples pass through unchanged" do
      assert {:error, :not_found} = ErrorAdapter.get_todo("t1", "42")
      assert {:error, :db_unavailable} = ErrorAdapter.list_todos("t1")
    end

    test "exceptions from impl propagate" do
      defmodule RaisingImpl do
        @behaviour TestContract.Plain

        @impl true
        def get_todo(_tenant_id, _id), do: raise("boom")

        @impl true
        def list_todos(_tenant_id), do: {:ok, []}

        @impl true
        def health_check, do: :ok
      end

      defmodule RaisingAdapter do
        use Skuld.Effects.Port.Adapter.Direct,
          contract: TestContract,
          impl: RaisingImpl
      end

      assert_raise RuntimeError, "boom", fn ->
        RaisingAdapter.get_todo("t1", "42")
      end
    end
  end
end
