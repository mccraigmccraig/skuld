defmodule Skuld.Effects.Port.ContractTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Throw, as: ThrowResult
  alias Skuld.Effects.Port
  alias Skuld.Effects.Throw

  # ---------------------------------------------------------------
  # Test contract modules (defined at compile time)
  # ---------------------------------------------------------------

  defmodule TestContract do
    use DoubleDown.Contract

    defcallback(
      get_todo(tenant_id :: String.t(), id :: String.t()) ::
        {:ok, map()} | {:error, term()}
    )

    defcallback(
      list_todos(tenant_id :: String.t()) ::
        {:ok, [map()]} | {:error, term()}
    )

    # No {:ok, T} in return type — bang auto-detected as not needed
    defcallback(health_check() :: :ok)
  end

  # Contract with bare return type
  defmodule BareReturnContract do
    use DoubleDown.Contract

    defcallback(count_items(category :: String.t()) :: integer())
  end

  defmodule TestContractWithDoc do
    use DoubleDown.Contract

    @doc "Custom documentation for find_user"
    defcallback(
      find_user(id :: integer()) ::
        {:ok, map()} | {:error, term()}
    )

    defcallback(other_op(x :: term()) :: {:ok, term()} | {:error, term()})
  end

  # Effectful contracts for each test contract
  defmodule TestEffectful do
    use Skuld.Effects.Port.EffectfulContract, double_down_contract: TestContract
  end

  defmodule BareReturnEffectful do
    use Skuld.Effects.Port.EffectfulContract, double_down_contract: BareReturnContract
  end

  # Facade modules for each test contract (point at effectful contracts)
  defmodule TestFacade do
    use Skuld.Effects.Port.Facade, contract: TestEffectful
  end

  defmodule BareReturnFacade do
    use Skuld.Effects.Port.Facade, contract: BareReturnEffectful
  end

  # Implementation module for dispatch tests
  defmodule TestImpl do
    @behaviour TestContract

    @impl true
    def get_todo(tenant_id, id) do
      {:ok, %{tenant_id: tenant_id, id: id, source: :impl}}
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

  # ---------------------------------------------------------------
  # Plain/Effectful Behaviour Submodule Tests
  # ---------------------------------------------------------------

  describe "contract @callback generation" do
    test "contract modules have behaviour_info" do
      assert is_list(TestContract.behaviour_info(:callbacks))
      assert is_list(BareReturnContract.behaviour_info(:callbacks))
    end

    test "contract has callbacks with correct arities" do
      callbacks = TestContract.behaviour_info(:callbacks)
      assert {:get_todo, 2} in callbacks
      assert {:list_todos, 1} in callbacks
      assert {:health_check, 0} in callbacks
    end

    test "contract callbacks match all operations" do
      ops = TestContract.__callbacks__()
      callbacks = TestContract.behaviour_info(:callbacks)

      for op <- ops do
        assert {op.name, op.arity} in callbacks,
               "Expected callback #{op.name}/#{op.arity}"
      end

      assert length(callbacks) == length(ops)
    end

    test "implementation module satisfies contract behaviour" do
      callbacks = TestContract.behaviour_info(:callbacks)

      for {name, arity} <- callbacks do
        assert function_exported?(TestImpl, name, arity),
               "TestImpl should export #{name}/#{arity}"
      end
    end
  end

  describe "Effectful contract and Facade generation" do
    test "effectful contracts exist for each contract" do
      assert Code.ensure_loaded?(TestEffectful)
      assert Code.ensure_loaded?(BareReturnEffectful)
    end

    test "effectful contract has callbacks with correct arities" do
      callbacks = TestEffectful.behaviour_info(:callbacks)
      assert {:get_todo, 2} in callbacks
      assert {:list_todos, 1} in callbacks
      assert {:health_check, 0} in callbacks
    end

    test "effectful callbacks match all contract operations" do
      ops = TestContract.__callbacks__()
      callbacks = TestEffectful.behaviour_info(:callbacks)

      for op <- ops do
        assert {op.name, op.arity} in callbacks,
               "Expected Effectful callback #{op.name}/#{op.arity}"
      end

      assert length(callbacks) == length(ops)
    end

    test "facade caller functions satisfy effectful behaviour" do
      callbacks = TestEffectful.behaviour_info(:callbacks)

      for {name, arity} <- callbacks do
        assert function_exported?(TestFacade, name, arity),
               "Facade should export #{name}/#{arity} to satisfy Effectful behaviour"
      end
    end

    test "facade callers return computations" do
      comp = TestFacade.get_todo("t1", "id1")
      assert is_function(comp, 2), "Caller should return a computation (2-arity function)"

      comp = TestFacade.list_todos("t1")
      assert is_function(comp, 2)

      comp = TestFacade.health_check()
      assert is_function(comp, 2)
    end
  end

  # (Effectful submodule docs test removed — effectful contracts are now
  #  defined explicitly by the user, not auto-generated as submodules)

  # ---------------------------------------------------------------
  # Contract Macro Tests
  # ---------------------------------------------------------------

  describe "defcallback generates caller functions on EffectPort" do
    test "with correct arity for multi-param operation" do
      assert function_exported?(TestFacade, :get_todo, 2)
    end

    test "with correct arity for single-param operation" do
      assert function_exported?(TestFacade, :list_todos, 1)
    end

    test "with correct arity for zero-param operation" do
      assert function_exported?(TestFacade, :health_check, 0)
    end

    test "caller returns a computation" do
      comp = TestFacade.get_todo("t1", "id1")
      assert is_function(comp, 2)
    end
  end

  describe "effectful facades do not auto-generate bang variants" do
    test "no bang for {:ok, T} | {:error, T} return type" do
      refute function_exported?(TestFacade, :get_todo!, 2)
      refute function_exported?(TestFacade, :list_todos!, 1)
    end

    test "no bang for bare return types" do
      refute function_exported?(BareReturnFacade, :count_items!, 1)
    end

    test "no bang for :ok return type" do
      refute function_exported?(TestFacade, :health_check!, 0)
    end
  end

  describe "defcallback generates @callback definitions on contract" do
    test "contract module defines behaviour callbacks directly" do
      assert function_exported?(TestContract, :behaviour_info, 1)
      callbacks = TestContract.behaviour_info(:callbacks)
      assert {:get_todo, 2} in callbacks
    end
  end

  describe "defcallback generates __key__ helpers on EffectPort" do
    test "__key__ helper exists with operation name + params arity" do
      # __key__(:get_todo, tenant_id, id) => arity 3
      assert function_exported?(TestFacade, :__key__, 3)
      # __key__(:list_todos, tenant_id) => arity 2
      assert function_exported?(TestFacade, :__key__, 2)
      # __key__(:health_check) => arity 1
      assert function_exported?(TestFacade, :__key__, 1)
    end

    test "__key__ helper matches Port.key/3 output" do
      key_from_helper = TestFacade.__key__(:get_todo, "t1", "id1")
      key_from_port = Port.key(TestEffectful, :get_todo, ["t1", "id1"])
      assert key_from_helper == key_from_port
    end

    test "__key__ helper for zero-arg operation" do
      key_from_helper = TestFacade.__key__(:health_check)
      key_from_port = Port.key(TestEffectful, :health_check, [])
      assert key_from_helper == key_from_port
    end
  end

  describe "defcallback generates __callbacks__/0" do
    test "returns list of operation metadata" do
      ops = TestContract.__callbacks__()
      assert is_list(ops)
      assert length(ops) == 3
    end

    test "operation metadata includes name and params" do
      ops = TestContract.__callbacks__()
      names = Enum.map(ops, & &1.name)
      assert :get_todo in names
      assert :list_todos in names
      assert :health_check in names
    end

    test "operation metadata includes arity" do
      ops = TestContract.__callbacks__()
      get_todo = Enum.find(ops, &(&1.name == :get_todo))
      assert get_todo.arity == 2
      assert get_todo.params == [:tenant_id, :id]

      health = Enum.find(ops, &(&1.name == :health_check))
      assert health.arity == 0
      assert health.params == []
    end
  end

  describe "multiple defcallback declarations in one module" do
    test "all operations are generated on EffectPort" do
      # TestContract has 3 operations
      assert function_exported?(TestFacade, :get_todo, 2)
      assert function_exported?(TestFacade, :list_todos, 1)
      assert function_exported?(TestFacade, :health_check, 0)
      assert length(TestContract.__callbacks__()) == 3
    end
  end

  describe "defcallback with zero params" do
    test "generates zero-arity caller on EffectPort" do
      comp = TestFacade.health_check()
      assert is_function(comp, 2)
    end

    test "generates single-arity __key__ helper on EffectPort" do
      key = TestFacade.__key__(:health_check)
      assert {TestEffectful, :health_check, _} = key
    end
  end

  describe "compile error on default args" do
    test "raises CompileError when \\\\ is used in defcallback" do
      assert_raise CompileError, ~r/does not support default arguments/, fn ->
        Code.compile_string("""
        defmodule DefaultArgsContract do
          use DoubleDown.Contract

          defcallback bad_op(id :: String.t(), limit \\\\ 20) ::
                    {:ok, term()} | {:error, term()}
        end
        """)
      end
    end
  end

  describe "compile error on invalid syntax" do
    test "raises CompileError for missing return type" do
      assert_raise CompileError, fn ->
        Code.compile_string("""
        defmodule BadSyntaxContract do
          use DoubleDown.Contract

          defcallback bad_op(id :: String.t())
        end
        """)
      end
    end
  end

  describe "auto-generated @doc" do
    # Code.fetch_docs/1 requires .beam files on disk. We compile modules
    # to a temp dir and fetch docs via the beam file path.

    defp fetch_docs_from_compiled(source, suffix) do
      # Ensure docs chunk is included in compiled beam
      Code.put_compiler_option(:docs, true)
      compiled = Code.compile_string(source)
      dir = System.tmp_dir!()

      # Find the target module
      {mod, beam} =
        if suffix do
          Enum.find(compiled, fn {mod, _beam} ->
            inspect(mod) |> String.ends_with?(suffix)
          end)
        else
          # Find the contract module (not any submodule)
          Enum.find(compiled, fn {mod, _beam} ->
            mod_name = inspect(mod)

            not String.ends_with?(mod_name, ".Port") and
              not String.ends_with?(mod_name, ".Effectful")
          end)
        end

      path = Path.join(dir, "Elixir.#{inspect(mod)}.beam")
      File.write!(path, beam)

      try do
        Code.fetch_docs(path)
      after
        File.rm(path)
      end
    end

    test "caller and key helper docs are generated on facade" do
      {:docs_v1, _, _, _, _, _, docs} =
        fetch_docs_from_compiled(
          """
          defmodule DocVerifyContract do
            use DoubleDown.Contract
            defcallback get_item(id :: String.t()) :: {:ok, map()} | {:error, term()}
          end

          defmodule DocVerifyFacade do
            use Skuld.Effects.Port.Facade, contract: DocVerifyContract
          end
          """,
          "DocVerifyFacade"
        )

      # Caller doc
      caller_doc =
        Enum.find(docs, fn
          {{:function, :get_item, 1}, _, _, _, _} -> true
          _ -> false
        end)

      assert caller_doc != nil
      {{:function, :get_item, 1}, _, _, %{"en" => caller_content}, _} = caller_doc
      assert caller_content =~ "Port operation"

      # No bang variant generated
      bang_doc =
        Enum.find(docs, fn
          {{:function, :get_item!, 1}, _, _, _, _} -> true
          _ -> false
        end)

      assert bang_doc == nil

      # Key helper doc
      key_doc =
        Enum.find(docs, fn
          {{:function, :__key__, 2}, _, _, _, _} -> true
          _ -> false
        end)

      assert key_doc != nil
      {{:function, :__key__, 2}, _, _, %{"en" => key_content}, _} = key_doc
      assert key_content =~ "test stub key"
    end

    test "user @doc override is respected on facade" do
      {:docs_v1, _, _, _, _, _, docs} =
        fetch_docs_from_compiled(
          """
          defmodule DocOverrideContract do
            use DoubleDown.Contract

            @doc "My custom doc"
            defcallback find_user(id :: integer()) :: {:ok, map()} | {:error, term()}
          end

          defmodule DocOverrideFacade do
            use Skuld.Effects.Port.Facade, contract: DocOverrideContract
          end
          """,
          "DocOverrideFacade"
        )

      find_user_doc =
        Enum.find(docs, fn
          {{:function, :find_user, 1}, _, _, _, _} -> true
          _ -> false
        end)

      assert find_user_doc != nil

      {{:function, :find_user, 1}, _, _, %{"en" => doc_content}, _} = find_user_doc
      assert doc_content =~ "My custom doc"
    end
  end

  # ---------------------------------------------------------------
  # Dispatch Tests (Contract → Implementation)
  # ---------------------------------------------------------------

  describe "contract → implementation module dispatch" do
    test "bare module resolver dispatches to implementation" do
      comp =
        TestFacade.get_todo("tenant1", "id1")
        |> Port.with_handler(%{TestEffectful => TestImpl})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{tenant_id: "tenant1", id: "id1", source: :impl}} = result
    end

    test "zero-arg operation dispatches correctly" do
      comp =
        TestFacade.health_check()
        |> Port.with_handler(%{TestEffectful => TestImpl})

      {result, _env} = Comp.run(comp)
      assert :ok = result
    end

    test ":direct resolver dispatches to contract module itself" do
      # This only works if the contract module also implements the functions
      # In our test, TestContract has generated callers but they return computations
      # so :direct would call the generated def, which is a computation — not useful
      # but the dispatch mechanism works
      # We test :direct with a non-contract module
      defmodule DirectImpl do
        def get_todo(tenant_id, id) do
          {:ok, %{tenant_id: tenant_id, id: id, source: :direct}}
        end
      end

      comp =
        Port.request(DirectImpl, :get_todo, ["t1", "i1"])
        |> Port.with_handler(%{DirectImpl => :direct})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{source: :direct}} = result
    end
  end

  describe "contract + test_handler with key helpers" do
    test "__key__ helper produces matching keys for test stubs" do
      responses = %{
        TestFacade.__key__(:get_todo, "t1", "id1") => {:ok, %{id: "id1", name: "Test Todo"}}
      }

      comp =
        TestFacade.get_todo("t1", "id1")
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: "id1", name: "Test Todo"}} = result
    end

    test "zero-arg __key__ helper works with test stubs" do
      responses = %{
        TestFacade.__key__(:health_check) => :ok
      }

      comp =
        TestFacade.health_check()
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert :ok = result
    end

    test "missing stub throws port_not_stubbed" do
      responses = %{}

      comp =
        TestFacade.get_todo("t1", "id1")
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:port_not_stubbed, {TestEffectful, :get_todo, _}}} = result
    end
  end

  describe "contract + fn_handler" do
    test "pattern matching on contract module" do
      handler = fn
        TestEffectful, :get_todo, [tid, id] ->
          {:ok, %{tenant_id: tid, id: id, source: :fn_handler}}

        TestEffectful, :health_check, [] ->
          :ok
      end

      comp =
        TestFacade.get_todo("t1", "id1")
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{tenant_id: "t1", id: "id1", source: :fn_handler}} = result
    end
  end

  describe "contract + function resolver" do
    test "function resolver receives args as list" do
      resolver = fn _mod, _name, [tid, id] ->
        {:ok, %{tenant_id: tid, id: id, source: :fn_resolver}}
      end

      comp =
        TestFacade.get_todo("t1", "id1")
        |> Port.with_handler(%{TestEffectful => resolver})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{source: :fn_resolver}} = result
    end
  end

  describe "contract + {module, function} resolver" do
    defmodule MFDispatcher do
      def dispatch(_mod, _name, [tid, id]) do
        {:ok, %{tenant_id: tid, id: id, source: :mf}}
      end
    end

    test "{module, function} resolver works with contract" do
      comp =
        TestFacade.get_todo("t1", "id1")
        |> Port.with_handler(%{TestEffectful => {MFDispatcher, :dispatch}})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{source: :mf}} = result
    end
  end

  describe "error cases" do
    test "implementation module missing function gives clear error" do
      defmodule IncompleteImpl do
        # Intentionally missing get_todo, list_todos, health_check
      end

      comp =
        TestFacade.get_todo("t1", "id1")
        |> Port.with_handler(%{TestEffectful => IncompleteImpl})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert %ThrowResult{
               error: {:port_failed, TestEffectful, :get_todo, %UndefinedFunctionError{}}
             } = result
    end

    test "unknown module in registry" do
      comp =
        TestFacade.get_todo("t1", "id1")
        |> Port.with_handler(%{SomeOtherModule => TestImpl})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:unknown_port_module, TestEffectful}} = result
    end
  end

  # ---------------------------------------------------------------
  # Integration Tests
  # ---------------------------------------------------------------

  describe "full integration: contract → impl → handler → run" do
    test "complete flow with runtime handler" do
      comp =
        TestFacade.get_todo("tenant1", "todo1")
        |> Port.with_handler(%{TestEffectful => TestImpl})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{tenant_id: "tenant1", id: "todo1", source: :impl}} = result
    end

    test "request! unwraps :ok with Throw integration" do
      comp =
        Port.request!(TestEffectful, :get_todo, ["tenant1", "todo1"])
        |> Port.with_handler(%{TestEffectful => TestImpl})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{tenant_id: "tenant1", id: "todo1", source: :impl} = result
    end

    test "request! throws on :error" do
      handler = fn
        TestEffectful, :get_todo, [_tid, _id] -> {:error, :not_found}
      end

      comp =
        Port.request!(TestEffectful, :get_todo, ["tenant1", "bad_id"])
        |> Port.with_fn_handler(handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: :not_found} = result
    end

    test "multiple contracts in one handler registry" do
      defmodule OtherContract do
        use DoubleDown.Contract

        defcallback(lookup(key :: String.t()) :: {:ok, term()} | {:error, term()})
      end

      defmodule OtherEffectful do
        use Skuld.Effects.Port.EffectfulContract, double_down_contract: OtherContract
      end

      defmodule OtherFacade do
        use Skuld.Effects.Port.Facade, contract: OtherEffectful
      end

      defmodule OtherImpl do
        @behaviour OtherContract

        @impl true
        def lookup(key) do
          {:ok, "value_for_#{key}"}
        end
      end

      comp =
        Comp.bind(TestFacade.get_todo("t1", "id1"), fn result1 ->
          Comp.bind(OtherFacade.lookup("mykey"), fn result2 ->
            {result1, result2}
          end)
        end)
        |> Port.with_handler(%{
          TestEffectful => TestImpl,
          OtherEffectful => OtherImpl
        })

      {result, _env} = Comp.run(comp)
      assert {{:ok, %{source: :impl}}, {:ok, "value_for_mykey"}} = result
    end
  end

  describe "request! unwrap and throw paths" do
    test "request! unwraps :ok tuple" do
      responses = %{
        TestFacade.__key__(:get_todo, "t1", "id1") => {:ok, %{id: "id1"}}
      }

      comp =
        Port.request!(TestEffectful, :get_todo, ["t1", "id1"])
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{id: "id1"} = result
    end

    test "request! throws on :error tuple" do
      responses = %{
        TestFacade.__key__(:get_todo, "t1", "bad") => {:error, :not_found}
      }

      comp =
        Port.request!(TestEffectful, :get_todo, ["t1", "bad"])
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: :not_found} = result
    end
  end

  # ---------------------------------------------------------------
  # Contract does NOT generate .Port (plain dispatch facade)
  # ---------------------------------------------------------------

  defmodule PlainDispatchContract do
    use DoubleDown.Contract

    defcallback greet(name :: String.t()) :: String.t()
  end

  defmodule PlainDispatchImpl do
    @behaviour PlainDispatchContract

    @impl true
    def greet(name), do: "Hello, #{name}!"
  end

  # Consuming app defines its own DoubleDown ContractFacade separately
  defmodule PlainDispatchContract.DDFacade do
    use DoubleDown.ContractFacade, contract: PlainDispatchContract, otp_app: :skuld_test
  end

  # Effectful contract
  defmodule PlainDispatchEffectful do
    use Skuld.Effects.Port.EffectfulContract, double_down_contract: PlainDispatchContract
  end

  # Consuming app defines its own effectful facade separately
  defmodule PlainDispatchFacade do
    use Skuld.Effects.Port.Facade, contract: PlainDispatchEffectful
  end

  describe "Contract/Facade separation" do
    test "Contract has __callbacks__/0 for facades to consume" do
      ops = PlainDispatchContract.__callbacks__()
      assert [%{name: :greet}] = ops
    end

    test "DoubleDown ContractFacade dispatches via Application config" do
      Application.put_env(:skuld_test, PlainDispatchContract, impl: PlainDispatchImpl)
      on_exit(fn -> Application.delete_env(:skuld_test, PlainDispatchContract) end)

      assert "Hello, Alice!" = PlainDispatchContract.DDFacade.greet("Alice")
    end

    test "Effectful facade generates callers" do
      assert function_exported?(PlainDispatchFacade, :greet, 1)

      comp = PlainDispatchFacade.greet("Bob")
      assert is_function(comp, 2)
    end

    test "Effectful facade dispatches via Port effect handler" do
      handler = fn PlainDispatchEffectful, :greet, ["Carol"] -> "Hi, Carol!" end

      comp =
        PlainDispatchFacade.greet("Carol")
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert "Hi, Carol!" = result
    end
  end

  # ---------------------------------------------------------------
  # Combined effectful contract + facade on same module
  # ---------------------------------------------------------------

  describe "combined effectful contract and facade on same module" do
    test "compiles and works correctly" do
      [{_contract, _}, {mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.CombinedContract do
          use DoubleDown.Contract
          defcallback greet(name :: String.t()) :: String.t()
          defcallback ping() :: :pong
        end

        defmodule Skuld.Test.Combined do
          use Skuld.Effects.Port.EffectfulContract,
            double_down_contract: Skuld.Test.CombinedContract
          use Skuld.Effects.Port.Facade,
            contract: Skuld.Test.Combined
        end
        """)

      # Has effectful callbacks
      callbacks = apply(mod, :behaviour_info, [:callbacks])
      assert {:greet, 1} in callbacks
      assert {:ping, 0} in callbacks

      # Has __callbacks__
      ops = apply(mod, :__callbacks__, [])
      assert length(ops) == 2

      # Has __port_effectful__?
      assert apply(mod, :__port_effectful__?, []) == true

      # Facade functions exist and return computations
      comp = apply(mod, :greet, ["Alice"])
      assert is_function(comp, 2)
    end

    test "dispatches correctly via Port handler" do
      [{_contract, _}, {mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.CombinedDispatchContract do
          use DoubleDown.Contract
          defcallback greet(name :: String.t()) :: String.t()
        end

        defmodule Skuld.Test.CombinedDispatch do
          use Skuld.Effects.Port.EffectfulContract,
            double_down_contract: Skuld.Test.CombinedDispatchContract
          use Skuld.Effects.Port.Facade,
            contract: Skuld.Test.CombinedDispatch
        end
        """)

      handler = fn ^mod, :greet, ["Alice"] -> "Hello, Alice!" end

      comp =
        apply(mod, :greet, ["Alice"])
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert "Hello, Alice!" = result
    end
  end

  # ---------------------------------------------------------------
  # Single-use shorthand: double_down_contract: on Facade
  # ---------------------------------------------------------------

  describe "Facade with double_down_contract: shorthand" do
    test "compiles and works correctly" do
      [{_contract, _}, {mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.ShorthandContract do
          use DoubleDown.Contract
          defcallback greet(name :: String.t()) :: String.t()
          defcallback ping() :: :pong
        end

        defmodule Skuld.Test.Shorthand do
          use Skuld.Effects.Port.Facade,
            double_down_contract: Skuld.Test.ShorthandContract
        end
        """)

      # Has effectful callbacks
      callbacks = apply(mod, :behaviour_info, [:callbacks])
      assert {:greet, 1} in callbacks
      assert {:ping, 0} in callbacks

      # Has __callbacks__
      ops = apply(mod, :__callbacks__, [])
      assert length(ops) == 2

      # Has __port_effectful__?
      assert apply(mod, :__port_effectful__?, []) == true

      # Facade functions exist and return computations
      comp = apply(mod, :greet, ["Alice"])
      assert is_function(comp, 2)
    end

    test "dispatches correctly via Port handler" do
      [{_contract, _}, {mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.ShorthandDispatchContract do
          use DoubleDown.Contract
          defcallback greet(name :: String.t()) :: String.t()
        end

        defmodule Skuld.Test.ShorthandDispatch do
          use Skuld.Effects.Port.Facade,
            double_down_contract: Skuld.Test.ShorthandDispatchContract
        end
        """)

      handler = fn ^mod, :greet, ["Alice"] -> "Hello, Alice!" end

      comp =
        apply(mod, :greet, ["Alice"])
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert "Hello, Alice!" = result
    end
  end

  # ---------------------------------------------------------------
  # Single-module pattern: use Skuld.Effects.Port.Facade (no options)
  # ---------------------------------------------------------------

  describe "single-module: use Skuld.Effects.Port.Facade (no options)" do
    test "compiles and has all required metadata" do
      [{mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.SingleMod do
          use Skuld.Effects.Port.Facade

          defcallback greet(name :: String.t()) :: String.t()
          defcallback ping() :: :pong
        end
        """)

      # Has effectful @callback declarations
      callbacks = apply(mod, :behaviour_info, [:callbacks])
      assert {:greet, 1} in callbacks
      assert {:ping, 0} in callbacks

      # __callbacks__/0 exists (generated by DoubleDown.Contract)
      ops = apply(mod, :__callbacks__, [])
      assert length(ops) == 2

      # __port_effectful__?/0 exists
      assert apply(mod, :__port_effectful__?, []) == true

      # Facade caller functions exist and return computations
      assert function_exported?(mod, :greet, 1)
      comp = apply(mod, :greet, ["Alice"])
      assert is_function(comp, 2)

      assert function_exported?(mod, :ping, 0)
      comp = apply(mod, :ping, [])
      assert is_function(comp, 2)

      # __key__ helpers exist
      assert function_exported?(mod, :__key__, 2)
      assert function_exported?(mod, :__key__, 1)
    end

    test "__callbacks__/0 returns plain operation metadata (not effectful)" do
      [{mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.SingleModMeta do
          use Skuld.Effects.Port.Facade

          defcallback get_todo(id :: String.t()) :: {:ok, map()} | {:error, term()}
        end
        """)

      ops = mod.__callbacks__()
      assert [op] = ops
      assert op.name == :get_todo
      assert op.params == [:id]
      assert op.arity == 1

      # __callbacks__/0 preserves original return type (not wrapped in computation())
      # This is metadata, not the behaviour contract
      assert op.return_type != nil
    end

    test "dispatches correctly via Port handler" do
      [{mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.SingleModDispatch do
          use Skuld.Effects.Port.Facade

          defcallback greet(name :: String.t()) :: String.t()
        end
        """)

      handler = fn ^mod, :greet, ["Alice"] -> "Hello from single-module!" end

      comp =
        apply(mod, :greet, ["Alice"])
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert "Hello from single-module!" = result
    end

    test "__key__ helper matches Port.key/3 output" do
      [{mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.SingleModKey do
          use Skuld.Effects.Port.Facade

          defcallback find_user(id :: integer()) :: {:ok, map()} | {:error, term()}
        end
        """)

      key_from_helper = apply(mod, :__key__, [:find_user, 42])
      key_from_port = Port.key(mod, :find_user, [42])
      assert key_from_helper == key_from_port
    end

    test "zero-arg operation works complete flow" do
      [{mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.SingleModZero do
          use Skuld.Effects.Port.Facade

          defcallback health_check() :: :ok
        end
        """)

      handler = fn ^mod, :health_check, [] -> :ok end

      comp =
        apply(mod, :health_check, [])
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert :ok = result
    end

    test "compile error when no defcallback declarations" do
      assert_raise CompileError, ~r/has no defcallback declarations/, fn ->
        Code.compile_string("""
        defmodule Skuld.Test.SingleModEmpty do
          use Skuld.Effects.Port.Facade
        end
        """)
      end
    end

    test "single-module is also the contract for handler dispatch" do
      # The single module serves as both contract and facade — handlers
      # pattern-match on the module itself.
      [{mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.SingleModAsContract do
          use Skuld.Effects.Port.Facade

          defcallback add(a :: integer(), b :: integer()) :: integer()
        end
        """)

      handler = fn ^mod, :add, [1, 2] -> 3 end

      comp =
        apply(mod, :add, [1, 2])
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert 3 = result
    end

    test "works with test_handler and key helpers" do
      [{mod, _}] =
        Code.compile_string("""
        defmodule Skuld.Test.SingleModTestHandler do
          use Skuld.Effects.Port.Facade

          defcallback lookup(key :: String.t()) :: {:ok, term()} | {:error, term()}
        end
        """)

      key = apply(mod, :__key__, [:lookup, "k1"])

      responses = %{key => {:ok, "value_for_k1"}}

      comp =
        apply(mod, :lookup, ["k1"])
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert {:ok, "value_for_k1"} = result
    end
  end
end
