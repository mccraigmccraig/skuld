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
    use HexPort.Contract

    defport(
      get_todo(tenant_id :: String.t(), id :: String.t()) ::
        {:ok, map()} | {:error, term()}
    )

    defport(
      list_todos(tenant_id :: String.t()) ::
        {:ok, [map()]} | {:error, term()}
    )

    # No {:ok, T} in return type — bang auto-detected as not needed
    defport(health_check() :: :ok)
  end

  # Contract with bang: false to suppress auto-generated bang
  defmodule NoBangContract do
    use HexPort.Contract

    defport(get_item(id :: String.t()) :: {:ok, map()} | {:error, term()}, bang: false)
  end

  # Contract with bang: true to force bang on non-ok/error return type
  defmodule ForceBangContract do
    use HexPort.Contract

    defport(find_user(id :: String.t()) :: map() | nil, bang: true)
  end

  # Contract with custom unwrap function
  defmodule CustomBangContract do
    use HexPort.Contract

    defport(find_user(id :: String.t()) :: map() | nil,
      bang: fn
        nil -> {:error, :not_found}
        user -> {:ok, user}
      end
    )
  end

  # Contract with bare return type (no bang auto-generated)
  defmodule BareReturnContract do
    use HexPort.Contract

    defport(count_items(category :: String.t()) :: integer())
  end

  defmodule TestContractWithDoc do
    use HexPort.Contract

    @doc "Custom documentation for find_user"
    defport(
      find_user(id :: integer()) ::
        {:ok, map()} | {:error, term()}
    )

    defport(other_op(x :: term()) :: {:ok, term()} | {:error, term()})
  end

  # Effectful contracts for each test contract
  defmodule TestEffectful do
    use Skuld.Effects.Port.EffectfulContract, hex_port_contract: TestContract
  end

  defmodule NoBangEffectful do
    use Skuld.Effects.Port.EffectfulContract, hex_port_contract: NoBangContract
  end

  defmodule ForceBangEffectful do
    use Skuld.Effects.Port.EffectfulContract, hex_port_contract: ForceBangContract
  end

  defmodule CustomBangEffectful do
    use Skuld.Effects.Port.EffectfulContract, hex_port_contract: CustomBangContract
  end

  defmodule BareReturnEffectful do
    use Skuld.Effects.Port.EffectfulContract, hex_port_contract: BareReturnContract
  end

  # Facade modules for each test contract (point at effectful contracts)
  defmodule TestFacade do
    use Skuld.Effects.Port.Facade, contract: TestEffectful
  end

  defmodule NoBangFacade do
    use Skuld.Effects.Port.Facade, contract: NoBangEffectful
  end

  defmodule ForceBangFacade do
    use Skuld.Effects.Port.Facade, contract: ForceBangEffectful
  end

  defmodule CustomBangFacade do
    use Skuld.Effects.Port.Facade, contract: CustomBangEffectful
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
      assert is_list(NoBangContract.behaviour_info(:callbacks))
      assert is_list(ForceBangContract.behaviour_info(:callbacks))
      assert is_list(CustomBangContract.behaviour_info(:callbacks))
      assert is_list(BareReturnContract.behaviour_info(:callbacks))
    end

    test "contract has callbacks with correct arities" do
      callbacks = TestContract.behaviour_info(:callbacks)
      assert {:get_todo, 2} in callbacks
      assert {:list_todos, 1} in callbacks
      assert {:health_check, 0} in callbacks
    end

    test "contract callbacks match all operations" do
      ops = TestContract.__port_operations__()
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
      assert Code.ensure_loaded?(NoBangEffectful)
      assert Code.ensure_loaded?(ForceBangEffectful)
      assert Code.ensure_loaded?(CustomBangEffectful)
      assert Code.ensure_loaded?(BareReturnEffectful)
    end

    test "effectful contract has callbacks with correct arities" do
      callbacks = TestEffectful.behaviour_info(:callbacks)
      assert {:get_todo, 2} in callbacks
      assert {:list_todos, 1} in callbacks
      assert {:health_check, 0} in callbacks
    end

    test "effectful callbacks match all contract operations" do
      ops = TestContract.__port_operations__()
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

  describe "defport generates caller functions on EffectPort" do
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

  describe "defport generates bang variants on EffectPort" do
    test "for operations with {:ok, T} return type (auto-detect)" do
      assert function_exported?(TestFacade, :get_todo!, 2)
      assert function_exported?(TestFacade, :list_todos!, 1)
    end

    test "not for operations without {:ok, T} return type (auto-detect)" do
      refute function_exported?(TestFacade, :health_check!, 0)
    end

    test "not for bare return types (auto-detect)" do
      refute function_exported?(BareReturnFacade, :count_items!, 1)
    end

    test "bang returns a computation" do
      comp = TestFacade.get_todo!("t1", "id1")
      assert is_function(comp, 2)
    end
  end

  describe "bang: false suppresses bang generation" do
    test "no bang variant even with {:ok, T} return type" do
      # NoBangContract has {:ok, map()} | {:error, term()} but bang: false
      refute function_exported?(NoBangFacade, :get_item!, 1)
    end

    test "caller still generated" do
      assert function_exported?(NoBangFacade, :get_item, 1)
    end
  end

  describe "bang: true forces bang generation" do
    test "bang variant generated for non-ok/error return type" do
      assert function_exported?(ForceBangFacade, :find_user!, 1)
    end

    test "forced bang returns a computation" do
      comp = ForceBangFacade.find_user!("u1")
      assert is_function(comp, 2)
    end
  end

  describe "bang: custom_fn generates bang with custom unwrap" do
    test "bang variant generated with custom unwrap" do
      assert function_exported?(CustomBangFacade, :find_user!, 1)
    end

    test "custom bang returns a computation" do
      comp = CustomBangFacade.find_user!("u1")
      assert is_function(comp, 2)
    end

    test "custom bang unwraps success through custom function" do
      handler = fn CustomBangEffectful, :find_user, ["u1"] ->
        %{id: "u1", name: "Alice"}
      end

      comp =
        CustomBangFacade.find_user!("u1")
        |> Port.with_fn_handler(handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{id: "u1", name: "Alice"} = result
    end

    test "custom bang throws on error via custom function" do
      handler = fn CustomBangEffectful, :find_user, ["bad"] ->
        nil
      end

      comp =
        CustomBangFacade.find_user!("bad")
        |> Port.with_fn_handler(handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: :not_found} = result
    end
  end

  describe "defport generates @callback definitions on contract" do
    test "contract module defines behaviour callbacks directly" do
      assert function_exported?(TestContract, :behaviour_info, 1)
      callbacks = TestContract.behaviour_info(:callbacks)
      assert {:get_todo, 2} in callbacks
    end
  end

  describe "defport generates key helpers on EffectPort" do
    test "key helper exists with operation name + params arity" do
      # key(:get_todo, tenant_id, id) => arity 3
      assert function_exported?(TestFacade, :key, 3)
      # key(:list_todos, tenant_id) => arity 2
      assert function_exported?(TestFacade, :key, 2)
      # key(:health_check) => arity 1
      assert function_exported?(TestFacade, :key, 1)
    end

    test "key helper matches Port.key/3 output" do
      key_from_helper = TestFacade.key(:get_todo, "t1", "id1")
      key_from_port = Port.key(TestEffectful, :get_todo, ["t1", "id1"])
      assert key_from_helper == key_from_port
    end

    test "key helper for zero-arg operation" do
      key_from_helper = TestFacade.key(:health_check)
      key_from_port = Port.key(TestEffectful, :health_check, [])
      assert key_from_helper == key_from_port
    end
  end

  describe "defport generates __port_operations__/0" do
    test "returns list of operation metadata" do
      ops = TestContract.__port_operations__()
      assert is_list(ops)
      assert length(ops) == 3
    end

    test "operation metadata includes name and params" do
      ops = TestContract.__port_operations__()
      names = Enum.map(ops, & &1.name)
      assert :get_todo in names
      assert :list_todos in names
      assert :health_check in names
    end

    test "operation metadata includes arity" do
      ops = TestContract.__port_operations__()
      get_todo = Enum.find(ops, &(&1.name == :get_todo))
      assert get_todo.arity == 2
      assert get_todo.params == [:tenant_id, :id]

      health = Enum.find(ops, &(&1.name == :health_check))
      assert health.arity == 0
      assert health.params == []
    end
  end

  describe "multiple defport declarations in one module" do
    test "all operations are generated on EffectPort" do
      # TestContract has 3 operations
      assert function_exported?(TestFacade, :get_todo, 2)
      assert function_exported?(TestFacade, :list_todos, 1)
      assert function_exported?(TestFacade, :health_check, 0)
      assert length(TestContract.__port_operations__()) == 3
    end
  end

  describe "defport with zero params" do
    test "generates zero-arity caller on EffectPort" do
      comp = TestFacade.health_check()
      assert is_function(comp, 2)
    end

    test "does not generate bang for non-ok/error return type" do
      # health_check returns :ok (bare atom), no {:ok, T} pattern
      refute function_exported?(TestFacade, :health_check!, 0)
    end

    test "generates single-arity key helper on EffectPort" do
      key = TestFacade.key(:health_check)
      assert {TestEffectful, :health_check, _} = key
    end
  end

  describe "compile error on default args" do
    test "raises CompileError when \\\\ is used in defport" do
      assert_raise CompileError, ~r/does not support default arguments/, fn ->
        Code.compile_string("""
        defmodule DefaultArgsContract do
          use HexPort.Contract

          defport bad_op(id :: String.t(), limit \\\\ 20) ::
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
          use HexPort.Contract

          defport bad_op(id :: String.t())
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

    test "caller, bang, and key helper docs are generated on facade" do
      {:docs_v1, _, _, _, _, _, docs} =
        fetch_docs_from_compiled(
          """
          defmodule DocVerifyContract do
            use HexPort.Contract
            defport get_item(id :: String.t()) :: {:ok, map()} | {:error, term()}
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

      # Bang doc
      bang_doc =
        Enum.find(docs, fn
          {{:function, :get_item!, 1}, _, _, _, _} -> true
          _ -> false
        end)

      assert bang_doc != nil
      {{:function, :get_item!, 1}, _, _, %{"en" => bang_content}, _} = bang_doc
      assert bang_content =~ "unwraps"

      # Key helper doc
      key_doc =
        Enum.find(docs, fn
          {{:function, :key, 2}, _, _, _, _} -> true
          _ -> false
        end)

      assert key_doc != nil
      {{:function, :key, 2}, _, _, %{"en" => key_content}, _} = key_doc
      assert key_content =~ "test stub key"
    end

    test "user @doc override is respected on facade" do
      {:docs_v1, _, _, _, _, _, docs} =
        fetch_docs_from_compiled(
          """
          defmodule DocOverrideContract do
            use HexPort.Contract

            @doc "My custom doc"
            defport find_user(id :: integer()) :: {:ok, map()} | {:error, term()}
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
    test "key helper produces matching keys for test stubs" do
      responses = %{
        TestFacade.key(:get_todo, "t1", "id1") => {:ok, %{id: "id1", name: "Test Todo"}}
      }

      comp =
        TestFacade.get_todo("t1", "id1")
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: "id1", name: "Test Todo"}} = result
    end

    test "zero-arg key helper works with test stubs" do
      responses = %{
        TestFacade.key(:health_check) => :ok
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

    test "bang variant with Throw integration" do
      comp =
        TestFacade.get_todo!("tenant1", "todo1")
        |> Port.with_handler(%{TestEffectful => TestImpl})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{tenant_id: "tenant1", id: "todo1", source: :impl} = result
    end

    test "bang variant throws on error" do
      handler = fn
        TestEffectful, :get_todo, [_tid, _id] -> {:error, :not_found}
      end

      comp =
        TestFacade.get_todo!("tenant1", "bad_id")
        |> Port.with_fn_handler(handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: :not_found} = result
    end

    test "multiple contracts in one handler registry" do
      defmodule OtherContract do
        use HexPort.Contract

        defport(lookup(key :: String.t()) :: {:ok, term()} | {:error, term()})
      end

      defmodule OtherEffectful do
        use Skuld.Effects.Port.EffectfulContract, hex_port_contract: OtherContract
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
            Comp.pure({result1, result2})
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

  describe "contract with Throw integration (request! unwrap and throw paths)" do
    test "request! unwraps :ok tuple" do
      responses = %{
        TestFacade.key(:get_todo, "t1", "id1") => {:ok, %{id: "id1"}}
      }

      comp =
        TestFacade.get_todo!("t1", "id1")
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{id: "id1"} = result
    end

    test "request! throws on :error tuple" do
      responses = %{
        TestFacade.key(:get_todo, "t1", "bad") => {:error, :not_found}
      }

      comp =
        TestFacade.get_todo!("t1", "bad")
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
    use HexPort.Contract

    defport greet(name :: String.t()) :: String.t()
  end

  defmodule PlainDispatchImpl do
    @behaviour PlainDispatchContract

    @impl true
    def greet(name), do: "Hello, #{name}!"
  end

  # Consuming app defines its own HexPort facade separately
  defmodule PlainDispatchContract.HexPortFacade do
    use HexPort.Facade, contract: PlainDispatchContract, otp_app: :skuld_test
  end

  # Effectful contract
  defmodule PlainDispatchEffectful do
    use Skuld.Effects.Port.EffectfulContract, hex_port_contract: PlainDispatchContract
  end

  # Consuming app defines its own effectful facade separately
  defmodule PlainDispatchFacade do
    use Skuld.Effects.Port.Facade, contract: PlainDispatchEffectful
  end

  describe "Contract/Facade separation" do
    test "Contract has __port_operations__/0 for facades to consume" do
      ops = PlainDispatchContract.__port_operations__()
      assert [%{name: :greet}] = ops
    end

    test "HexPort facade dispatches via Application config" do
      Application.put_env(:skuld_test, PlainDispatchContract, impl: PlainDispatchImpl)
      on_exit(fn -> Application.delete_env(:skuld_test, PlainDispatchContract) end)

      assert "Hello, Alice!" = PlainDispatchContract.HexPortFacade.greet("Alice")
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
      Code.compile_string("""
      defmodule Skuld.Test.CombinedContract do
        use HexPort.Contract
        defport greet(name :: String.t()) :: String.t()
        defport ping() :: :pong
      end

      defmodule Skuld.Test.Combined do
        use Skuld.Effects.Port.EffectfulContract,
          hex_port_contract: Skuld.Test.CombinedContract
        use Skuld.Effects.Port.Facade,
          contract: Skuld.Test.Combined
      end
      """)

      mod = Skuld.Test.Combined

      # Has effectful callbacks
      callbacks = apply(mod, :behaviour_info, [:callbacks])
      assert {:greet, 1} in callbacks
      assert {:ping, 0} in callbacks

      # Has __port_operations__
      ops = apply(mod, :__port_operations__, [])
      assert length(ops) == 2

      # Has __port_effectful__?
      assert apply(mod, :__port_effectful__?, []) == true

      # Facade functions exist and return computations
      comp = apply(mod, :greet, ["Alice"])
      assert is_function(comp, 2)
    end

    test "dispatches correctly via Port handler" do
      Code.compile_string("""
      defmodule Skuld.Test.CombinedDispatchContract do
        use HexPort.Contract
        defport greet(name :: String.t()) :: String.t()
      end

      defmodule Skuld.Test.CombinedDispatch do
        use Skuld.Effects.Port.EffectfulContract,
          hex_port_contract: Skuld.Test.CombinedDispatchContract
        use Skuld.Effects.Port.Facade,
          contract: Skuld.Test.CombinedDispatch
      end
      """)

      mod = Skuld.Test.CombinedDispatch
      handler = fn ^mod, :greet, ["Alice"] -> "Hello, Alice!" end

      comp =
        apply(mod, :greet, ["Alice"])
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert "Hello, Alice!" = result
    end
  end
end
