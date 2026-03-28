defmodule Skuld.Effects.PortTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Throw, as: ThrowResult
  alias Skuld.Effects.Port
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Writer

  # Test module - returns {:ok, _} | {:error, _} result tuples
  # Accepts positional args
  defmodule TestQueries do
    def find_user(id) do
      {:ok, %{id: id, name: "User #{id}"}}
    end

    def find_user_or_error(id) when id < 0 do
      {:error, {:not_found, :user, id}}
    end

    def find_user_or_error(id) do
      {:ok, %{id: id, name: "User #{id}"}}
    end

    def list_users(limit) do
      {:ok, Enum.map(1..limit, &%{id: &1, name: "User #{&1}"})}
    end

    def failing_request(_arg) do
      raise "Request failed!"
    end

    def multi_param(id, name) do
      {:ok, %{id: id, name: name}}
    end

    def no_args do
      {:ok, :healthy}
    end
  end

  # Test implementation module - dispatches to same-named functions
  defmodule TestImplModule do
    def find_user(id) do
      {:ok, %{id: id, name: "Impl #{id}"}}
    end
  end

  describe "request/3" do
    test "creates a request computation returning result tuple" do
      comp =
        Port.request(TestQueries, :find_user, [123])
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 123, name: "User 123"}} = result
    end

    test "returns error tuple as-is" do
      comp =
        Port.request(TestQueries, :find_user_or_error, [-1])
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:error, {:not_found, :user, -1}} = result
    end

    test "default args is empty list" do
      comp =
        Port.request(TestQueries, :no_args)
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:ok, :healthy} = result
    end

    test "handles multiple positional args" do
      comp =
        Port.request(TestQueries, :multi_param, [42, "Alice"])
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 42, name: "Alice"}} = result
    end
  end

  describe "with_handler/2 - :direct resolver" do
    test "dispatches directly to module function" do
      comp =
        Port.request(TestQueries, :find_user, [42])
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 42, name: "User 42"}} = result
    end
  end

  describe "request!/3" do
    test "unwraps {:ok, value} and returns value" do
      comp =
        Port.request!(TestQueries, :find_user, [42])
        |> Port.with_handler(%{TestQueries => :direct})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{id: 42, name: "User 42"} = result
    end

    test "dispatches Throw on {:error, reason}" do
      comp =
        Port.request!(TestQueries, :find_user_or_error, [-1])
        |> Port.with_handler(%{TestQueries => :direct})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:not_found, :user, -1}} = result
    end

    test "unwraps list results" do
      comp =
        Port.request!(TestQueries, :list_users, [3])
        |> Port.with_handler(%{TestQueries => :direct})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert [%{id: 1}, %{id: 2}, %{id: 3}] = result
    end

    test "works with test handler stubs" do
      responses = %{
        Port.key(TestQueries, :find_user, [999]) => {:ok, %{id: 999, name: "Stubbed"}}
      }

      comp =
        Port.request!(TestQueries, :find_user, [999])
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{id: 999, name: "Stubbed"} = result
    end

    test "throws on stubbed error response" do
      responses = %{
        Port.key(TestQueries, :find_user, [404]) => {:error, :user_not_found}
      }

      comp =
        Port.request!(TestQueries, :find_user, [404])
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: :user_not_found} = result
    end
  end

  describe "with_handler/2 - function resolver" do
    test "dispatches to anonymous function" do
      resolver = fn _mod, _name, [id] ->
        {:ok, %{id: id, name: "Custom #{id}"}}
      end

      comp =
        Port.request(TestQueries, :find_user, [99])
        |> Port.with_handler(%{TestQueries => resolver})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 99, name: "Custom 99"}} = result
    end
  end

  describe "with_handler/2 - {module, function} resolver" do
    defmodule MFResolver do
      def resolve(_mod, _name, [id]) do
        {:ok, %{id: id, name: "MF #{id}"}}
      end
    end

    test "dispatches to module/function tuple" do
      comp =
        Port.request(TestQueries, :find_user, [77])
        |> Port.with_handler(%{TestQueries => {MFResolver, :resolve}})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 77, name: "MF 77"}} = result
    end
  end

  describe "with_handler/2 - module resolver" do
    test "dispatches to implementation module functions directly" do
      comp =
        Port.request(TestQueries, :find_user, [55])
        |> Port.with_handler(%{TestQueries => TestImplModule})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 55, name: "Impl 55"}} = result
    end
  end

  describe "with_handler/2 - error handling" do
    test "throws on unknown module" do
      comp =
        Port.request(UnknownModule, :some_request, [])
        |> Port.with_handler(%{TestQueries => :direct})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:unknown_port_module, UnknownModule}} = result
    end

    test "throws on request exception" do
      comp =
        Port.request(TestQueries, :failing_request, [:anything])
        |> Port.with_handler(%{TestQueries => :direct})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert %ThrowResult{error: {:port_failed, TestQueries, :failing_request, %RuntimeError{}}} =
               result
    end
  end

  describe "with_test_handler/2" do
    test "returns stubbed response for matching key" do
      responses = %{
        Port.key(TestQueries, :find_user, [123]) => {:ok, %{id: 123, name: "Stubbed Alice"}}
      }

      comp =
        Port.request(TestQueries, :find_user, [123])
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 123, name: "Stubbed Alice"}} = result
    end

    test "throws on missing stub" do
      responses = %{
        Port.key(TestQueries, :find_user, [123]) => {:ok, %{id: 123, name: "Alice"}}
      }

      comp =
        Port.request(TestQueries, :find_user, [999])
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:port_not_stubbed, {TestQueries, :find_user, _}}} = result
    end

    test "can stub error responses" do
      responses = %{
        Port.key(TestQueries, :find_user, [404]) => {:error, :not_found}
      }

      comp =
        Port.request(TestQueries, :find_user, [404])
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert {:error, :not_found} = result
    end

    test "matches multi-arg keys by position" do
      responses = %{
        Port.key(TestQueries, :multi_param, [99, "Bob"]) => {:ok, %{id: 99, name: "Stubbed Bob"}}
      }

      comp =
        Port.request(TestQueries, :multi_param, [99, "Bob"])
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 99, name: "Stubbed Bob"}} = result
    end
  end

  describe "with_test_handler/2 - fallback option" do
    test "uses fallback function when key not found" do
      responses = %{
        Port.key(TestQueries, :find_user, [1]) => {:ok, %{id: 1, name: "Stubbed"}}
      }

      fallback = fn
        TestQueries, :find_user, [id] -> {:ok, %{id: id, name: "Fallback #{id}"}}
      end

      comp =
        Port.request(TestQueries, :find_user, [999])
        |> Port.with_test_handler(responses, fallback: fallback)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 999, name: "Fallback 999"}} = result
    end

    test "prefers exact match over fallback" do
      responses = %{
        Port.key(TestQueries, :find_user, [123]) => {:ok, %{id: 123, name: "Exact"}}
      }

      fallback = fn
        TestQueries, :find_user, [_id] -> {:ok, %{name: "Fallback"}}
      end

      comp =
        Port.request(TestQueries, :find_user, [123])
        |> Port.with_test_handler(responses, fallback: fallback)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 123, name: "Exact"}} = result
    end

    test "fallback can handle multiple modules" do
      responses = %{}

      fallback = fn
        TestQueries, :find_user, [id] -> {:ok, %{id: id, name: "User"}}
        TestQueries, :list_users, [n] -> {:ok, Enum.map(1..n, &%{id: &1})}
      end

      comp1 =
        Port.request(TestQueries, :find_user, [42])
        |> Port.with_test_handler(responses, fallback: fallback)

      comp2 =
        Port.request(TestQueries, :list_users, [2])
        |> Port.with_test_handler(responses, fallback: fallback)

      {result1, _} = Comp.run(comp1)
      {result2, _} = Comp.run(comp2)

      assert {:ok, %{id: 42, name: "User"}} = result1
      assert {:ok, [%{id: 1}, %{id: 2}]} = result2
    end

    test "fallback FunctionClauseError throws port_not_handled" do
      responses = %{}

      fallback = fn
        TestQueries, :find_user, [_id] ->
          {:ok, %{name: "Found"}}
          # No clause for :other_query
      end

      comp =
        Port.request(TestQueries, :other_query, [:bar])
        |> Port.with_test_handler(responses, fallback: fallback)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert %ThrowResult{error: {:port_not_handled, TestQueries, :other_query, [:bar], _}} =
               result
    end
  end

  describe "with_fn_handler/2" do
    test "dispatches to handler function" do
      handler = fn
        TestQueries, :find_user, [id] -> {:ok, %{id: id, name: "FnHandler"}}
      end

      comp =
        Port.request(TestQueries, :find_user, [42])
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 42, name: "FnHandler"}} = result
    end

    test "supports pattern matching with pins" do
      expected_id = 123

      handler = fn
        TestQueries, :find_user, [^expected_id] -> {:ok, %{name: "Expected"}}
        TestQueries, :find_user, [_other] -> {:ok, %{name: "Other"}}
      end

      comp1 =
        Port.request(TestQueries, :find_user, [123])
        |> Port.with_fn_handler(handler)

      comp2 =
        Port.request(TestQueries, :find_user, [456])
        |> Port.with_fn_handler(handler)

      {result1, _} = Comp.run(comp1)
      {result2, _} = Comp.run(comp2)

      assert {:ok, %{name: "Expected"}} = result1
      assert {:ok, %{name: "Other"}} = result2
    end

    test "supports pattern matching with guards" do
      handler = fn
        TestQueries, :list_users, [n] when n > 100 -> {:error, :limit_too_high}
        TestQueries, :list_users, [n] -> {:ok, Enum.to_list(1..n)}
      end

      comp1 =
        Port.request(TestQueries, :list_users, [50])
        |> Port.with_fn_handler(handler)

      comp2 =
        Port.request(TestQueries, :list_users, [200])
        |> Port.with_fn_handler(handler)

      {result1, _} = Comp.run(comp1)
      {result2, _} = Comp.run(comp2)

      assert {:ok, list} = result1
      assert length(list) == 50
      assert {:error, :limit_too_high} = result2
    end

    test "supports wildcard matching" do
      handler = fn
        TestQueries, _any_function, _any_args -> :wildcard_matched
      end

      comp =
        Port.request(TestQueries, :anything, [:foo, :bar, 123])
        |> Port.with_fn_handler(handler)

      {result, _env} = Comp.run(comp)
      assert :wildcard_matched = result
    end

    test "returns error for unhandled request" do
      handler = fn
        TestQueries, :known_query, _args -> :ok
      end

      comp =
        Port.request(TestQueries, :unknown_query, [1])
        |> Port.with_fn_handler(handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert %ThrowResult{error: {:port_not_handled, TestQueries, :unknown_query, [1], _}} =
               result
    end

    test "returns error for handler exception" do
      handler = fn
        TestQueries, :find_user, _args -> raise "Handler exploded!"
      end

      comp =
        Port.request(TestQueries, :find_user, [1])
        |> Port.with_fn_handler(handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert %ThrowResult{error: {:port_handler_error, TestQueries, :find_user, %RuntimeError{}}} =
               result
    end

    test "handles multiple modules" do
      defmodule OtherQueries do
      end

      handler = fn
        TestQueries, :find_user, [id] -> {:ok, %{source: :test, id: id}}
        OtherQueries, :find_user, [id] -> {:ok, %{source: :other, id: id}}
      end

      comp1 =
        Port.request(TestQueries, :find_user, [1])
        |> Port.with_fn_handler(handler)

      comp2 =
        Port.request(OtherQueries, :find_user, [2])
        |> Port.with_fn_handler(handler)

      {result1, _} = Comp.run(comp1)
      {result2, _} = Comp.run(comp2)

      assert {:ok, %{source: :test, id: 1}} = result1
      assert {:ok, %{source: :other, id: 2}} = result2
    end
  end

  describe "key/3" do
    test "same args produce same key" do
      key1 = Port.key(TestQueries, :find_user, [1, 2])
      key2 = Port.key(TestQueries, :find_user, [1, 2])
      assert key1 == key2
    end

    test "different args produce different keys" do
      key1 = Port.key(TestQueries, :find_user, [1])
      key2 = Port.key(TestQueries, :find_user, [2])
      assert key1 != key2
    end

    test "arg order matters" do
      key1 = Port.key(TestQueries, :multi_param, [1, "a"])
      key2 = Port.key(TestQueries, :multi_param, ["a", 1])
      assert key1 != key2
    end

    test "handles nested maps in args" do
      key1 = Port.key(TestQueries, :find_user, [%{a: 1, b: 2}])
      key2 = Port.key(TestQueries, :find_user, [%{b: 2, a: 1}])
      assert key1 == key2
    end

    test "handles structs in args" do
      key1 = Port.key(TestQueries, :find_user, [%URI{host: "example.com", port: 80}])
      key2 = Port.key(TestQueries, :find_user, [%URI{host: "example.com", port: 80}])
      assert key1 == key2
    end

    test "handles lists in args (preserves order)" do
      key1 = Port.key(TestQueries, :find_user, [[1, 2, 3]])
      key2 = Port.key(TestQueries, :find_user, [[1, 2, 3]])
      key3 = Port.key(TestQueries, :find_user, [[3, 2, 1]])
      assert key1 == key2
      assert key1 != key3
    end

    test "handles tuples in args" do
      key1 = Port.key(TestQueries, :find_user, [{1, 10}])
      key2 = Port.key(TestQueries, :find_user, [{1, 10}])
      assert key1 == key2
    end

    test "empty args list produces consistent key" do
      key1 = Port.key(TestQueries, :no_args, [])
      key2 = Port.key(TestQueries, :no_args, [])
      assert key1 == key2
    end
  end

  describe "composition" do
    test "multiple requests in sequence using request!" do
      responses = %{
        Port.key(TestQueries, :find_user, [1]) => {:ok, %{id: 1, name: "Alice"}},
        Port.key(TestQueries, :find_user, [2]) => {:ok, %{id: 2, name: "Bob"}}
      }

      comp =
        Comp.bind(Port.request!(TestQueries, :find_user, [1]), fn user1 ->
          Comp.bind(Port.request!(TestQueries, :find_user, [2]), fn user2 ->
            Comp.pure([user1, user2])
          end)
        end)
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert [%{name: "Alice"}, %{name: "Bob"}] = result
    end

    test "multiple requests with request returning result tuples" do
      responses = %{
        Port.key(TestQueries, :find_user, [1]) => {:ok, %{id: 1, name: "Alice"}},
        Port.key(TestQueries, :find_user, [2]) => {:error, :not_found}
      }

      comp =
        Comp.bind(Port.request(TestQueries, :find_user, [1]), fn result1 ->
          Comp.bind(Port.request(TestQueries, :find_user, [2]), fn result2 ->
            Comp.pure([result1, result2])
          end)
        end)
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert [{:ok, %{name: "Alice"}}, {:error, :not_found}] = result
    end

    test "combines with other effects" do
      alias Skuld.Effects.State

      responses = %{
        Port.key(TestQueries, :find_user, [1]) => {:ok, %{id: 1, name: "Alice"}}
      }

      comp =
        Comp.bind(Port.request!(TestQueries, :find_user, [1]), fn user ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              Comp.pure({user, count})
            end)
          end)
        end)
        |> Port.with_test_handler(responses)
        |> State.with_handler(0)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert {%{name: "Alice"}, 0} = result
    end
  end

  describe "try_catch integration" do
    test "fn_handler works with Throw.try_catch" do
      handler = fn
        TestQueries, :find_user, [id] when id > 0 -> {:ok, %{id: id}}
        TestQueries, :find_user, [_id] -> {:error, :invalid_id}
      end

      comp1 =
        Port.request(TestQueries, :find_user, [1])
        |> Port.with_fn_handler(handler)
        |> Throw.try_catch()
        |> Throw.with_handler()

      comp2 =
        Port.request(TestQueries, :find_user, [-1])
        |> Port.with_fn_handler(handler)
        |> Throw.try_catch()
        |> Throw.with_handler()

      {result1, _} = Comp.run(comp1)
      {result2, _} = Comp.run(comp2)

      assert {:ok, {:ok, %{id: 1}}} = result1
      assert {:ok, {:error, :invalid_id}} = result2
    end
  end

  # ---------------------------------------------------------------
  # Effectful resolver tests
  # ---------------------------------------------------------------

  # Effectful impl — returns computations, not plain values
  defmodule EffectfulImpl do
    def find_user(id) do
      Comp.pure({:ok, %{id: id, name: "Effectful #{id}"}})
    end

    def find_user_or_error(id) when id < 0 do
      Comp.pure({:error, {:not_found, :user, id}})
    end

    def find_user_or_error(id) do
      Comp.pure({:ok, %{id: id, name: "Effectful #{id}"}})
    end

    def no_args do
      Comp.pure({:ok, :healthy})
    end
  end

  # Effectful impl that uses effects internally
  defmodule StatefulEffectfulImpl do
    alias Skuld.Effects.State

    def find_user(id) do
      Comp.bind(State.get(), fn count ->
        Comp.bind(State.put(count + 1), fn _ ->
          Comp.pure({:ok, %{id: id, name: "Stateful #{id}", call_count: count + 1}})
        end)
      end)
    end
  end

  # Effectful impl that throws
  defmodule ThrowingEffectfulImpl do
    def find_user(_id) do
      Throw.throw(:something_went_wrong)
    end
  end

  describe "effectful resolver" do
    test "inlines computation from effectful impl" do
      comp =
        Port.request(TestQueries, :find_user, [42])
        |> Port.with_handler(%{TestQueries => {:effectful, EffectfulImpl}})

      {result, _} = Comp.run(comp)
      assert {:ok, %{id: 42, name: "Effectful 42"}} = result
    end

    test "works with request!/3 unwrapping" do
      comp =
        Port.request!(TestQueries, :find_user, [42])
        |> Port.with_handler(%{TestQueries => {:effectful, EffectfulImpl}})
        |> Throw.with_handler()

      {result, _} = Comp.run(comp)
      assert %{id: 42, name: "Effectful 42"} = result
    end

    test "request!/3 throws on error from effectful impl" do
      comp =
        Port.request!(TestQueries, :find_user_or_error, [-1])
        |> Port.with_handler(%{TestQueries => {:effectful, EffectfulImpl}})
        |> Throw.try_catch()
        |> Throw.with_handler()

      {result, _} = Comp.run(comp)
      assert {:error, {:not_found, :user, -1}} = result
    end

    test "effectful impl participates in consumer's effect context (State)" do
      alias Skuld.Effects.State

      comp =
        Port.request(TestQueries, :find_user, [1])
        |> Comp.bind(fn first_result ->
          Comp.bind(Port.request(TestQueries, :find_user, [2]), fn second_result ->
            Comp.pure({first_result, second_result})
          end)
        end)
        |> Port.with_handler(%{TestQueries => {:effectful, StatefulEffectfulImpl}})
        |> State.with_handler(0)

      {result, _} = Comp.run(comp)

      assert {{:ok, %{id: 1, call_count: 1}}, {:ok, %{id: 2, call_count: 2}}} = result
    end

    test "effectful impl's throws handled by consumer's Throw handler" do
      comp =
        Port.request(TestQueries, :find_user, [42])
        |> Port.with_handler(%{TestQueries => {:effectful, ThrowingEffectfulImpl}})
        |> Throw.try_catch()
        |> Throw.with_handler()

      {result, _} = Comp.run(comp)
      assert {:error, :something_went_wrong} = result
    end

    test "zero-arg effectful operation" do
      comp =
        Port.request(TestQueries, :no_args, [])
        |> Port.with_handler(%{TestQueries => {:effectful, EffectfulImpl}})

      {result, _} = Comp.run(comp)
      assert {:ok, :healthy} = result
    end

    test "mixed registry with plain and effectful resolvers" do
      comp =
        Comp.bind(Port.request(TestQueries, :find_user, [1]), fn plain_result ->
          Comp.bind(Port.request(TestImplModule, :find_user, [2]), fn effectful_result ->
            Comp.pure({plain_result, effectful_result})
          end)
        end)
        |> Port.with_handler(%{
          TestQueries => :direct,
          TestImplModule => {:effectful, EffectfulImpl}
        })

      {result, _} = Comp.run(comp)

      assert {{:ok, %{id: 1, name: "User 1"}}, {:ok, %{id: 2, name: "Effectful 2"}}} = result
    end

    test "unknown module still errors" do
      comp =
        Port.request(UnknownModule, :find_user, [42])
        |> Port.with_handler(%{TestQueries => {:effectful, EffectfulImpl}})
        |> Throw.try_catch()
        |> Throw.with_handler()

      {result, _} = Comp.run(comp)
      assert {:error, {:unknown_port_module, UnknownModule}} = result
    end
  end

  # ---------------------------------------------------------------
  # Nested with_handler registry merging tests
  # ---------------------------------------------------------------

  defmodule ModuleA do
    def do_a(x), do: {:ok, {:a, x}}
  end

  defmodule ModuleB do
    def do_b(x), do: {:ok, {:b, x}}
  end

  defmodule ModuleAv2 do
    def do_a(x), do: {:ok, {:a_v2, x}}
  end

  describe "nested with_handler/2 - registry merging" do
    test "inner handler merges registries with outer handler" do
      # Outer registers ModuleA, inner registers ModuleB.
      # A request to ModuleA should still work inside the inner scope.
      comp =
        Comp.bind(Port.request(ModuleA, :do_a, [1]), fn a_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [2]), fn b_result ->
            Comp.pure({a_result, b_result})
          end)
        end)
        |> Port.with_handler(%{ModuleB => :direct})
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      assert {{:ok, {:a, 1}}, {:ok, {:b, 2}}} = result
    end

    test "inner handler overrides conflicting entries (inner wins)" do
      # Both register ModuleA, inner should win.
      comp =
        Port.request(ModuleA, :do_a, [42])
        |> Port.with_handler(%{ModuleA => ModuleAv2})
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      # Inner wins → dispatched to ModuleAv2
      assert {:ok, {:a_v2, 42}} = result
    end

    test "outer registry restored after inner scope exits" do
      # After inner scope exits, outer scope should use its own registry.
      inner_comp =
        Port.request(ModuleA, :do_a, [1])
        |> Port.with_handler(%{ModuleA => ModuleAv2})

      comp =
        Comp.bind(inner_comp, fn inner_result ->
          Comp.bind(Port.request(ModuleA, :do_a, [2]), fn outer_result ->
            Comp.pure({inner_result, outer_result})
          end)
        end)
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      # Inner used ModuleAv2, outer restored to :direct
      assert {{:ok, {:a_v2, 1}}, {:ok, {:a, 2}}} = result
    end

    test "three levels of nesting merge correctly" do
      # Level 1: ModuleA, Level 2: adds ModuleB, Level 3: overrides ModuleA
      innermost_comp =
        Comp.bind(Port.request(ModuleA, :do_a, [1]), fn a_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [2]), fn b_result ->
            Comp.pure({a_result, b_result})
          end)
        end)
        |> Port.with_handler(%{ModuleA => ModuleAv2})

      middle_comp =
        innermost_comp
        |> Port.with_handler(%{ModuleB => :direct})

      comp =
        middle_comp
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      # Innermost overrides ModuleA to ModuleAv2, ModuleB from middle
      assert {{:ok, {:a_v2, 1}}, {:ok, {:b, 2}}} = result
    end

    test "inner scope does not leak entries to outer scope" do
      # Inner adds ModuleB, but outer should not have it after inner exits.
      inner_comp =
        Port.request(ModuleB, :do_b, [1])
        |> Port.with_handler(%{ModuleB => :direct})

      # Wrap the outer ModuleB request in try_catch so it doesn't short-circuit
      outer_request =
        Port.request(ModuleB, :do_b, [2])
        |> Throw.try_catch()

      comp =
        Comp.bind(inner_comp, fn inner_result ->
          Comp.bind(outer_request, fn outer_result ->
            Comp.pure({inner_result, outer_result})
          end)
        end)
        |> Port.with_handler(%{ModuleA => :direct})
        |> Throw.with_handler()

      {result, _} = Comp.run(comp)
      # Inner succeeded, outer failed because ModuleB was not leaked
      assert {{:ok, {:b, 1}}, {:error, {:unknown_port_module, ModuleB}}} = result
    end

    test "inner effectful resolver merged with outer plain resolver" do
      comp =
        Comp.bind(Port.request(ModuleA, :do_a, [1]), fn a_result ->
          Comp.bind(Port.request(TestQueries, :find_user, [42]), fn q_result ->
            Comp.pure({a_result, q_result})
          end)
        end)
        |> Port.with_handler(%{TestQueries => {:effectful, EffectfulImpl}})
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      assert {{:ok, {:a, 1}}, {:ok, %{id: 42, name: "Effectful 42"}}} = result
    end
  end

  # ---------------------------------------------------------------
  # Mixed handler mode tests
  # ---------------------------------------------------------------

  describe "mixed handler modes" do
    test "with_handler and with_test_handler compose for different modules" do
      responses = %{
        Port.key(ModuleB, :do_b, [99]) => {:ok, {:stubbed_b, 99}}
      }

      comp =
        Comp.bind(Port.request(ModuleA, :do_a, [1]), fn a_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [99]), fn b_result ->
            Comp.pure({a_result, b_result})
          end)
        end)
        |> Port.with_test_handler(responses)
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      # ModuleA dispatched via :direct, ModuleB via test stub
      assert {{:ok, {:a, 1}}, {:ok, {:stubbed_b, 99}}} = result
    end

    test "with_handler and with_fn_handler compose for different modules" do
      handler = fn
        ModuleB, :do_b, [x] -> {:ok, {:fn_b, x}}
      end

      comp =
        Comp.bind(Port.request(ModuleA, :do_a, [1]), fn a_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [42]), fn b_result ->
            Comp.pure({a_result, b_result})
          end)
        end)
        |> Port.with_fn_handler(handler)
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      # ModuleA dispatched via :direct, ModuleB via fn handler
      assert {{:ok, {:a, 1}}, {:ok, {:fn_b, 42}}} = result
    end

    test "module-specific entry overrides default test stub" do
      responses = %{
        Port.key(ModuleA, :do_a, [1]) => {:ok, {:stubbed_a, 1}},
        Port.key(ModuleB, :do_b, [2]) => {:ok, {:stubbed_b, 2}}
      }

      comp =
        Comp.bind(Port.request(ModuleA, :do_a, [1]), fn a_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [2]), fn b_result ->
            Comp.pure({a_result, b_result})
          end)
        end)
        |> Port.with_test_handler(responses)
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      # ModuleA goes to :direct (overrides stub), ModuleB goes to test stub
      assert {{:ok, {:a, 1}}, {:ok, {:stubbed_b, 2}}} = result
    end

    test "module-specific entry overrides default fn handler" do
      handler = fn
        _mod, :do_a, [x] -> {:ok, {:fn_a, x}}
        _mod, :do_b, [x] -> {:ok, {:fn_b, x}}
      end

      comp =
        Comp.bind(Port.request(ModuleA, :do_a, [1]), fn a_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [2]), fn b_result ->
            Comp.pure({a_result, b_result})
          end)
        end)
        |> Port.with_fn_handler(handler)
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      # ModuleA goes to :direct (overrides fn), ModuleB goes to fn handler
      assert {{:ok, {:a, 1}}, {:ok, {:fn_b, 2}}} = result
    end

    test "test_stub and fn_handler: inner default overrides outer default" do
      responses = %{
        Port.key(ModuleA, :do_a, [1]) => {:ok, {:stubbed, 1}}
      }

      fn_handler = fn
        _mod, _name, [x] -> {:ok, {:fn_result, x}}
      end

      comp =
        Port.request(ModuleA, :do_a, [1])
        |> Port.with_test_handler(responses)
        |> Port.with_fn_handler(fn_handler)

      {result, _} = Comp.run(comp)
      # Inner test_stub overrides outer fn_handler for :__default__
      assert {:ok, {:stubbed, 1}} = result
    end

    test "effectful resolver with test stub default for other modules" do
      responses = %{
        Port.key(ModuleB, :do_b, [5]) => {:ok, {:stubbed_b, 5}}
      }

      comp =
        Comp.bind(Port.request(TestQueries, :find_user, [42]), fn q_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [5]), fn b_result ->
            Comp.pure({q_result, b_result})
          end)
        end)
        |> Port.with_test_handler(responses)
        |> Port.with_handler(%{TestQueries => {:effectful, EffectfulImpl}})

      {result, _} = Comp.run(comp)
      assert {{:ok, %{id: 42, name: "Effectful 42"}}, {:ok, {:stubbed_b, 5}}} = result
    end

    test "test handler fallback works for unknown modules when mixed with runtime" do
      responses = %{
        Port.key(ModuleB, :do_b, [1]) => {:ok, {:exact_b, 1}}
      }

      fallback = fn
        mod, name, args -> {:ok, {:fallback, mod, name, args}}
      end

      comp =
        Comp.bind(Port.request(ModuleA, :do_a, [1]), fn a_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [1]), fn b_exact ->
            Comp.bind(Port.request(ModuleB, :do_b, [999]), fn b_fallback ->
              Comp.pure({a_result, b_exact, b_fallback})
            end)
          end)
        end)
        |> Port.with_test_handler(responses, fallback: fallback)
        |> Port.with_handler(%{ModuleA => :direct})

      {result, _} = Comp.run(comp)
      # ModuleA: :direct, ModuleB[1]: exact stub, ModuleB[999]: fallback
      assert {{:ok, {:a, 1}}, {:ok, {:exact_b, 1}}, {:ok, {:fallback, ModuleB, :do_b, [999]}}} =
               result
    end
  end

  # ---------------------------------------------------------------
  # Port-level :log option tests
  # ---------------------------------------------------------------

  # Helper: wrap a comp with Writer + output to capture the log alongside result.
  # Writer stores newest-first, so we reverse for chronological order.
  defp with_log_capture(comp, log_tag) do
    comp
    |> Writer.with_handler([],
      tag: log_tag,
      output: fn result, log -> {result, Enum.reverse(log)} end
    )
  end

  describe ":log option on with_handler — plain resolvers" do
    test "logs {mod, name, args, result} for :direct resolver" do
      comp =
        Port.request(TestQueries, :find_user, [42])
        |> Port.with_handler(%{TestQueries => :direct}, log: :port_log)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 42, name: "User 42"}},
              [{TestQueries, :find_user, [42], {:ok, %{id: 42, name: "User 42"}}}]} = result
    end

    test "logs for module resolver" do
      comp =
        Port.request(TestQueries, :find_user, [55])
        |> Port.with_handler(%{TestQueries => TestImplModule}, log: :port_log)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 55, name: "Impl 55"}},
              [{TestQueries, :find_user, [55], {:ok, %{id: 55, name: "Impl 55"}}}]} = result
    end

    test "logs for function resolver" do
      resolver = fn _mod, _name, [id] -> {:ok, %{id: id, name: "Custom"}} end

      comp =
        Port.request(TestQueries, :find_user, [7])
        |> Port.with_handler(%{TestQueries => resolver}, log: :port_log)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 7, name: "Custom"}},
              [{TestQueries, :find_user, [7], {:ok, %{id: 7, name: "Custom"}}}]} = result
    end

    test "logs for {module, function} resolver" do
      defmodule MFResolverForLog do
        def resolve(_mod, _name, [id]) do
          {:ok, %{id: id, name: "MF #{id}"}}
        end
      end

      comp =
        Port.request(TestQueries, :find_user, [77])
        |> Port.with_handler(%{TestQueries => {MFResolverForLog, :resolve}}, log: :port_log)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 77, name: "MF 77"}},
              [{TestQueries, :find_user, [77], {:ok, %{id: 77, name: "MF 77"}}}]} = result
    end
  end

  describe ":log option on with_test_handler" do
    test "logs stub responses" do
      responses = %{
        Port.key(TestQueries, :find_user, [123]) => {:ok, %{id: 123, name: "Stubbed"}}
      }

      comp =
        Port.request(TestQueries, :find_user, [123])
        |> Port.with_test_handler(responses, log: :port_log)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 123, name: "Stubbed"}},
              [{TestQueries, :find_user, [123], {:ok, %{id: 123, name: "Stubbed"}}}]} = result
    end

    test "logs fallback responses" do
      fallback = fn TestQueries, :find_user, [id] -> {:ok, %{id: id, name: "Fallback"}} end

      comp =
        Port.request(TestQueries, :find_user, [999])
        |> Port.with_test_handler(%{}, fallback: fallback, log: :port_log)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 999, name: "Fallback"}},
              [{TestQueries, :find_user, [999], {:ok, %{id: 999, name: "Fallback"}}}]} = result
    end
  end

  describe ":log option on with_fn_handler" do
    test "logs fn handler responses" do
      handler = fn TestQueries, :find_user, [id] -> {:ok, %{id: id, name: "FnHandler"}} end

      comp =
        Port.request(TestQueries, :find_user, [42])
        |> Port.with_fn_handler(handler, log: :port_log)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 42, name: "FnHandler"}},
              [{TestQueries, :find_user, [42], {:ok, %{id: 42, name: "FnHandler"}}}]} = result
    end
  end

  describe ":log option with effectful resolvers" do
    test "logs result after effectful computation completes" do
      comp =
        Port.request(TestQueries, :find_user, [42])
        |> Port.with_handler(%{TestQueries => {:effectful, EffectfulImpl}}, log: :port_log)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 42, name: "Effectful 42"}},
              [{TestQueries, :find_user, [42], {:ok, %{id: 42, name: "Effectful 42"}}}]} = result
    end

    test "effectful resolver with internal effects still logs correctly" do
      alias Skuld.Effects.State

      comp =
        Port.request(TestQueries, :find_user, [1])
        |> Port.with_handler(%{TestQueries => {:effectful, StatefulEffectfulImpl}},
          log: :port_log
        )
        |> State.with_handler(0)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 1, call_count: 1}},
              [{TestQueries, :find_user, [1], {:ok, %{id: 1, call_count: 1}}}]} = result
    end
  end

  describe ":log option — error/throw cases" do
    test "logs unknown module error" do
      comp =
        Port.request(UnknownModule, :some_fn, [:arg])
        |> Port.with_handler(%{TestQueries => :direct}, log: :port_log)
        |> Throw.with_handler()
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {%ThrowResult{error: {:unknown_port_module, UnknownModule}},
              [
                {UnknownModule, :some_fn, [:arg],
                 %ThrowResult{error: {:unknown_port_module, UnknownModule}}}
              ]} =
               result
    end

    test "logs runtime exception error" do
      comp =
        Port.request(TestQueries, :failing_request, [:boom])
        |> Port.with_handler(%{TestQueries => :direct}, log: :port_log)
        |> Throw.with_handler()
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {%ThrowResult{error: {:port_failed, TestQueries, :failing_request, %RuntimeError{}}},
              [
                {TestQueries, :failing_request, [:boom],
                 %ThrowResult{
                   error: {:port_failed, TestQueries, :failing_request, %RuntimeError{}}
                 }}
              ]} =
               result
    end

    test "logs port_not_stubbed error" do
      comp =
        Port.request(TestQueries, :find_user, [999])
        |> Port.with_test_handler(%{}, log: :port_log)
        |> Throw.with_handler()
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {%ThrowResult{error: {:port_not_stubbed, _key}},
              [{TestQueries, :find_user, [999], %ThrowResult{error: {:port_not_stubbed, _}}}]} =
               result
    end

    test "logs port_not_handled error from fn handler" do
      handler = fn TestQueries, :known_fn, _args -> :ok end

      comp =
        Port.request(TestQueries, :unknown_fn, [1])
        |> Port.with_fn_handler(handler, log: :port_log)
        |> Throw.with_handler()
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {%ThrowResult{error: {:port_not_handled, TestQueries, :unknown_fn, [1], _}},
              [
                {TestQueries, :unknown_fn, [1],
                 %ThrowResult{error: {:port_not_handled, TestQueries, :unknown_fn, [1], _}}}
              ]} =
               result
    end
  end

  describe ":log option — nested handlers" do
    test "inner :log overrides outer :log" do
      inner_comp =
        Port.request(ModuleA, :do_a, [1])
        |> Port.with_handler(%{ModuleA => :direct}, log: :inner_log)
        |> with_log_capture(:inner_log)

      comp =
        inner_comp
        |> Port.with_handler(%{}, log: :outer_log)
        |> with_log_capture(:outer_log)

      {result, _env} = Comp.run(comp)

      # Inner log captured the entry, outer log is empty
      assert {{{:ok, {:a, 1}}, [{ModuleA, :do_a, [1], {:ok, {:a, 1}}}]}, []} = result
    end

    test "outer :log active when inner scope has no :log" do
      inner_comp =
        Port.request(ModuleA, :do_a, [1])
        |> Port.with_handler(%{ModuleA => :direct})

      comp =
        Comp.bind(inner_comp, fn inner_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [2]), fn outer_result ->
            Comp.pure({inner_result, outer_result})
          end)
        end)
        |> Port.with_handler(%{ModuleB => :direct}, log: :outer_log)
        |> with_log_capture(:outer_log)

      {result, _env} = Comp.run(comp)

      # Both dispatches logged to :outer_log — inner scope inherits outer's log tag
      assert {{{:ok, {:a, 1}}, {:ok, {:b, 2}}},
              [
                {ModuleA, :do_a, [1], {:ok, {:a, 1}}},
                {ModuleB, :do_b, [2], {:ok, {:b, 2}}}
              ]} = result
    end

    test "inner :log restored to outer :log after inner scope exits" do
      inner_comp =
        Port.request(ModuleA, :do_a, [1])
        |> Port.with_handler(%{ModuleA => :direct}, log: :inner_log)
        |> with_log_capture(:inner_log)

      comp =
        Comp.bind(inner_comp, fn inner_result ->
          Comp.bind(Port.request(ModuleB, :do_b, [2]), fn outer_result ->
            Comp.pure({inner_result, outer_result})
          end)
        end)
        |> Port.with_handler(%{ModuleB => :direct}, log: :outer_log)
        |> with_log_capture(:outer_log)

      {result, _env} = Comp.run(comp)

      # Inner log got the inner dispatch, outer log got the outer dispatch
      assert {{{{:ok, {:a, 1}}, [{ModuleA, :do_a, [1], {:ok, {:a, 1}}}]}, {:ok, {:b, 2}}},
              [{ModuleB, :do_b, [2], {:ok, {:b, 2}}}]} = result
    end
  end

  describe ":log option — no logging when not set" do
    test "no Writer needed when :log not set" do
      # This should work without any Writer handler installed
      comp =
        Port.request(TestQueries, :find_user, [42])
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 42, name: "User 42"}} = result
    end

    test "existing Writer handler unaffected when :log not set" do
      comp =
        Comp.bind(Writer.tell(:my_tag, "manual entry"), fn _ ->
          Port.request(TestQueries, :find_user, [42])
        end)
        |> Port.with_handler(%{TestQueries => :direct})
        |> Writer.with_handler([],
          tag: :my_tag,
          output: fn result, log -> {result, Enum.reverse(log)} end
        )

      {result, _env} = Comp.run(comp)

      # Only the manual entry, no Port log entries
      assert {{:ok, %{id: 42}}, ["manual entry"]} = result
    end
  end

  describe ":log option — chronological order" do
    test "multiple dispatches logged in chronological order" do
      responses = %{
        Port.key(TestQueries, :find_user, [1]) => {:ok, %{id: 1}},
        Port.key(TestQueries, :find_user, [2]) => {:ok, %{id: 2}},
        Port.key(TestQueries, :find_user, [3]) => {:ok, %{id: 3}}
      }

      comp =
        Comp.bind(Port.request(TestQueries, :find_user, [1]), fn r1 ->
          Comp.bind(Port.request(TestQueries, :find_user, [2]), fn r2 ->
            Comp.bind(Port.request(TestQueries, :find_user, [3]), fn r3 ->
              Comp.pure({r1, r2, r3})
            end)
          end)
        end)
        |> Port.with_test_handler(responses, log: :port_log)
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      assert {{:ok, %{id: 1}}, {:ok, %{id: 2}}, {:ok, %{id: 3}}} = elem(result, 0)

      log = elem(result, 1)
      assert length(log) == 3

      assert [
               {TestQueries, :find_user, [1], {:ok, %{id: 1}}},
               {TestQueries, :find_user, [2], {:ok, %{id: 2}}},
               {TestQueries, :find_user, [3], {:ok, %{id: 3}}}
             ] = log
    end

    test "mixed resolver types logged in chronological order" do
      handler = fn ModuleB, :do_b, [x] -> {:ok, {:fn_b, x}} end

      comp =
        Comp.bind(Port.request(ModuleA, :do_a, [1]), fn r1 ->
          Comp.bind(Port.request(ModuleB, :do_b, [2]), fn r2 ->
            Comp.bind(Port.request(TestQueries, :find_user, [3]), fn r3 ->
              Comp.pure({r1, r2, r3})
            end)
          end)
        end)
        |> Port.with_fn_handler(handler, log: :port_log)
        |> Port.with_handler(
          %{
            ModuleA => :direct,
            TestQueries => {:effectful, EffectfulImpl}
          },
          log: :port_log
        )
        |> with_log_capture(:port_log)

      {result, _env} = Comp.run(comp)

      log = elem(result, 1)
      assert length(log) == 3

      assert [
               {ModuleA, :do_a, [1], {:ok, {:a, 1}}},
               {ModuleB, :do_b, [2], {:ok, {:fn_b, 2}}},
               {TestQueries, :find_user, [3], {:ok, %{id: 3, name: "Effectful 3"}}}
             ] = log
    end
  end
end
