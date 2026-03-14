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
    use Skuld.Effects.Port.Contract

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
    use Skuld.Effects.Port.Contract

    defport(get_item(id :: String.t()) :: {:ok, map()} | {:error, term()}, bang: false)
  end

  # Contract with bang: true to force bang on non-ok/error return type
  defmodule ForceBangContract do
    use Skuld.Effects.Port.Contract

    defport(find_user(id :: String.t()) :: map() | nil, bang: true)
  end

  # Contract with custom unwrap function
  defmodule CustomBangContract do
    use Skuld.Effects.Port.Contract

    defport(find_user(id :: String.t()) :: map() | nil,
      bang: fn
        nil -> {:error, :not_found}
        user -> {:ok, user}
      end
    )
  end

  # Contract with bare return type (no bang auto-generated)
  defmodule BareReturnContract do
    use Skuld.Effects.Port.Contract

    defport(count_items(category :: String.t()) :: integer())
  end

  defmodule TestContractWithDoc do
    use Skuld.Effects.Port.Contract

    @doc "Custom documentation for find_user"
    defport(
      find_user(id :: integer()) ::
        {:ok, map()} | {:error, term()}
    )

    defport(other_op(x :: term()) :: {:ok, term()} | {:error, term()})
  end

  # Implementation module for dispatch tests
  defmodule TestImpl do
    @behaviour TestContract.Consumer

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
  # Contract Macro Tests
  # ---------------------------------------------------------------

  describe "defport generates caller functions" do
    test "with correct arity for multi-param operation" do
      assert function_exported?(TestContract, :get_todo, 2)
    end

    test "with correct arity for single-param operation" do
      assert function_exported?(TestContract, :list_todos, 1)
    end

    test "with correct arity for zero-param operation" do
      assert function_exported?(TestContract, :health_check, 0)
    end

    test "caller returns a computation" do
      comp = TestContract.get_todo("t1", "id1")
      assert is_function(comp, 2)
    end
  end

  describe "defport generates bang variants" do
    test "for operations with {:ok, T} return type (auto-detect)" do
      assert function_exported?(TestContract, :get_todo!, 2)
      assert function_exported?(TestContract, :list_todos!, 1)
    end

    test "not for operations without {:ok, T} return type (auto-detect)" do
      refute function_exported?(TestContract, :health_check!, 0)
    end

    test "not for bare return types (auto-detect)" do
      refute function_exported?(BareReturnContract, :count_items!, 1)
    end

    test "bang returns a computation" do
      comp = TestContract.get_todo!("t1", "id1")
      assert is_function(comp, 2)
    end
  end

  describe "bang: false suppresses bang generation" do
    test "no bang variant even with {:ok, T} return type" do
      # NoBangContract has {:ok, map()} | {:error, term()} but bang: false
      refute function_exported?(NoBangContract, :get_item!, 1)
    end

    test "caller still generated" do
      assert function_exported?(NoBangContract, :get_item, 1)
    end
  end

  describe "bang: true forces bang generation" do
    test "bang variant generated for non-ok/error return type" do
      assert function_exported?(ForceBangContract, :find_user!, 1)
    end

    test "forced bang returns a computation" do
      comp = ForceBangContract.find_user!("u1")
      assert is_function(comp, 2)
    end
  end

  describe "bang: custom_fn generates bang with custom unwrap" do
    test "bang variant generated with custom unwrap" do
      assert function_exported?(CustomBangContract, :find_user!, 1)
    end

    test "custom bang returns a computation" do
      comp = CustomBangContract.find_user!("u1")
      assert is_function(comp, 2)
    end

    test "custom bang unwraps success through custom function" do
      handler = fn CustomBangContract, :find_user, ["u1"] ->
        %{id: "u1", name: "Alice"}
      end

      comp =
        CustomBangContract.find_user!("u1")
        |> Port.with_fn_handler(handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{id: "u1", name: "Alice"} = result
    end

    test "custom bang throws on error via custom function" do
      handler = fn CustomBangContract, :find_user, ["bad"] ->
        nil
      end

      comp =
        CustomBangContract.find_user!("bad")
        |> Port.with_fn_handler(handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: :not_found} = result
    end
  end

  describe "defport generates @callback definitions" do
    test "consumer callbacks are registered with correct arities" do
      callbacks = TestContract.Consumer.behaviour_info(:callbacks)

      assert {:get_todo, 2} in callbacks
      assert {:list_todos, 1} in callbacks
      assert {:health_check, 0} in callbacks
    end

    test "provider callbacks are registered with correct arities" do
      callbacks = TestContract.Provider.behaviour_info(:callbacks)

      assert {:get_todo, 2} in callbacks
      assert {:list_todos, 1} in callbacks
      assert {:health_check, 0} in callbacks
    end

    test "contract module itself no longer defines behaviour callbacks" do
      refute function_exported?(TestContract, :behaviour_info, 1)
    end
  end

  describe "defport generates key helpers" do
    test "key helper exists with operation name + params arity" do
      # key(:get_todo, tenant_id, id) => arity 3
      assert function_exported?(TestContract, :key, 3)
      # key(:list_todos, tenant_id) => arity 2
      assert function_exported?(TestContract, :key, 2)
      # key(:health_check) => arity 1
      assert function_exported?(TestContract, :key, 1)
    end

    test "key helper matches Port.key/3 output" do
      key_from_helper = TestContract.key(:get_todo, "t1", "id1")
      key_from_port = Port.key(TestContract, :get_todo, ["t1", "id1"])
      assert key_from_helper == key_from_port
    end

    test "key helper for zero-arg operation" do
      key_from_helper = TestContract.key(:health_check)
      key_from_port = Port.key(TestContract, :health_check, [])
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
    test "all operations are generated" do
      # TestContract has 3 operations
      assert function_exported?(TestContract, :get_todo, 2)
      assert function_exported?(TestContract, :list_todos, 1)
      assert function_exported?(TestContract, :health_check, 0)
      assert length(TestContract.__port_operations__()) == 3
    end
  end

  describe "defport with zero params" do
    test "generates zero-arity caller" do
      comp = TestContract.health_check()
      assert is_function(comp, 2)
    end

    test "does not generate bang for non-ok/error return type" do
      # health_check returns :ok (bare atom), no {:ok, T} pattern
      refute function_exported?(TestContract, :health_check!, 0)
    end

    test "generates single-arity key helper" do
      key = TestContract.key(:health_check)
      assert {TestContract, :health_check, _} = key
    end
  end

  describe "compile error on default args" do
    test "raises CompileError when \\\\ is used in defport" do
      assert_raise CompileError, ~r/does not support default arguments/, fn ->
        Code.compile_string("""
        defmodule DefaultArgsContract do
          use Skuld.Effects.Port.Contract

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
          use Skuld.Effects.Port.Contract

          defport bad_op(id :: String.t())
        end
        """)
      end
    end
  end

  describe "auto-generated @doc" do
    # Code.fetch_docs/1 requires .beam files on disk. We compile modules
    # to a temp dir and fetch docs via the beam file path.

    defp fetch_docs_from_compiled(source) do
      # Ensure docs chunk is included in compiled beam
      Code.put_compiler_option(:docs, true)
      compiled = Code.compile_string(source)
      dir = System.tmp_dir!()

      # Find the contract module (not Consumer or Provider submodule)
      {mod, beam} =
        Enum.find(compiled, fn {mod, _beam} ->
          mod_name = inspect(mod)

          not String.ends_with?(mod_name, ".Consumer") and
            not String.ends_with?(mod_name, ".Provider")
        end)

      path = Path.join(dir, "Elixir.#{inspect(mod)}.beam")
      File.write!(path, beam)

      try do
        Code.fetch_docs(path)
      after
        File.rm(path)
      end
    end

    test "caller, bang, and key helper docs are generated" do
      {:docs_v1, _, _, _, _, _, docs} =
        fetch_docs_from_compiled("""
        defmodule DocVerifyContract do
          use Skuld.Effects.Port.Contract

          defport get_item(id :: String.t()) :: {:ok, map()} | {:error, term()}
        end
        """)

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

    test "user @doc override is respected" do
      {:docs_v1, _, _, _, _, _, docs} =
        fetch_docs_from_compiled("""
        defmodule DocOverrideContract do
          use Skuld.Effects.Port.Contract

          @doc "My custom doc"
          defport find_user(id :: integer()) :: {:ok, map()} | {:error, term()}
        end
        """)

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
        TestContract.get_todo("tenant1", "id1")
        |> Port.with_handler(%{TestContract => TestImpl})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{tenant_id: "tenant1", id: "id1", source: :impl}} = result
    end

    test "zero-arg operation dispatches correctly" do
      comp =
        TestContract.health_check()
        |> Port.with_handler(%{TestContract => TestImpl})

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
        TestContract.key(:get_todo, "t1", "id1") => {:ok, %{id: "id1", name: "Test Todo"}}
      }

      comp =
        TestContract.get_todo("t1", "id1")
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: "id1", name: "Test Todo"}} = result
    end

    test "zero-arg key helper works with test stubs" do
      responses = %{
        TestContract.key(:health_check) => :ok
      }

      comp =
        TestContract.health_check()
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert :ok = result
    end

    test "missing stub throws port_not_stubbed" do
      responses = %{}

      comp =
        TestContract.get_todo("t1", "id1")
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:port_not_stubbed, {TestContract, :get_todo, _}}} = result
    end
  end

  describe "contract + fn_handler" do
    test "pattern matching on contract module" do
      handler = fn
        TestContract, :get_todo, [tid, id] ->
          {:ok, %{tenant_id: tid, id: id, source: :fn_handler}}

        TestContract, :health_check, [] ->
          :ok
      end

      comp =
        TestContract.get_todo("t1", "id1")
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
        TestContract.get_todo("t1", "id1")
        |> Port.with_handler(%{TestContract => resolver})

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
        TestContract.get_todo("t1", "id1")
        |> Port.with_handler(%{TestContract => {MFDispatcher, :dispatch}})

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
        TestContract.get_todo("t1", "id1")
        |> Port.with_handler(%{TestContract => IncompleteImpl})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert %ThrowResult{
               error: {:port_failed, TestContract, :get_todo, %UndefinedFunctionError{}}
             } = result
    end

    test "unknown module in registry" do
      comp =
        TestContract.get_todo("t1", "id1")
        |> Port.with_handler(%{SomeOtherModule => TestImpl})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:unknown_port_module, TestContract}} = result
    end
  end

  # ---------------------------------------------------------------
  # Integration Tests
  # ---------------------------------------------------------------

  describe "full integration: contract → impl → handler → run" do
    test "complete flow with runtime handler" do
      comp =
        TestContract.get_todo("tenant1", "todo1")
        |> Port.with_handler(%{TestContract => TestImpl})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{tenant_id: "tenant1", id: "todo1", source: :impl}} = result
    end

    test "bang variant with Throw integration" do
      comp =
        TestContract.get_todo!("tenant1", "todo1")
        |> Port.with_handler(%{TestContract => TestImpl})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{tenant_id: "tenant1", id: "todo1", source: :impl} = result
    end

    test "bang variant throws on error" do
      handler = fn
        TestContract, :get_todo, [_tid, _id] -> {:error, :not_found}
      end

      comp =
        TestContract.get_todo!("tenant1", "bad_id")
        |> Port.with_fn_handler(handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: :not_found} = result
    end

    test "multiple contracts in one handler registry" do
      defmodule OtherContract do
        use Skuld.Effects.Port.Contract

        defport(lookup(key :: String.t()) :: {:ok, term()} | {:error, term()})
      end

      defmodule OtherImpl do
        @behaviour OtherContract.Consumer

        @impl true
        def lookup(key) do
          {:ok, "value_for_#{key}"}
        end
      end

      comp =
        Comp.bind(TestContract.get_todo("t1", "id1"), fn result1 ->
          Comp.bind(OtherContract.lookup("mykey"), fn result2 ->
            Comp.pure({result1, result2})
          end)
        end)
        |> Port.with_handler(%{
          TestContract => TestImpl,
          OtherContract => OtherImpl
        })

      {result, _env} = Comp.run(comp)
      assert {{:ok, %{source: :impl}}, {:ok, "value_for_mykey"}} = result
    end
  end

  describe "contract with Throw integration (request! unwrap and throw paths)" do
    test "request! unwraps :ok tuple" do
      responses = %{
        TestContract.key(:get_todo, "t1", "id1") => {:ok, %{id: "id1"}}
      }

      comp =
        TestContract.get_todo!("t1", "id1")
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{id: "id1"} = result
    end

    test "request! throws on :error tuple" do
      responses = %{
        TestContract.key(:get_todo, "t1", "bad") => {:error, :not_found}
      }

      comp =
        TestContract.get_todo!("t1", "bad")
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: :not_found} = result
    end
  end
end
