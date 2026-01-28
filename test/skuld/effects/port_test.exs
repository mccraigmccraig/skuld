defmodule Skuld.Effects.PortTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Throw, as: ThrowResult
  alias Skuld.Effects.Port
  alias Skuld.Effects.Throw

  # Test module - returns {:ok, _} | {:error, _} result tuples
  defmodule TestQueries do
    def find_user(%{id: id}) do
      {:ok, %{id: id, name: "User #{id}"}}
    end

    def find_user_or_error(%{id: id}) when id < 0 do
      {:error, {:not_found, :user, id}}
    end

    def find_user_or_error(%{id: id}) do
      {:ok, %{id: id, name: "User #{id}"}}
    end

    def list_users(%{limit: limit}) do
      {:ok, Enum.map(1..limit, &%{id: &1, name: "User #{&1}"})}
    end

    def failing_request(_params) do
      raise "Request failed!"
    end
  end

  # Test handler module - wraps result in {:handled, _}
  defmodule TestPortHandler do
    def handle_port(mod, name, params) do
      result = apply(mod, name, [params])
      {:ok, {:handled, result}}
    end
  end

  describe "request/3" do
    test "creates a request computation returning result tuple" do
      comp =
        Port.request(TestQueries, :find_user, %{id: 123})
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 123, name: "User 123"}} = result
    end

    test "returns error tuple as-is" do
      comp =
        Port.request(TestQueries, :find_user_or_error, %{id: -1})
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:error, {:not_found, :user, -1}} = result
    end

    test "default params is empty map" do
      comp =
        Port.request(TestQueries, :list_users, %{limit: 2})
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:ok, [%{id: 1}, %{id: 2}]} = result
    end
  end

  describe "with_handler/2 - :direct resolver" do
    test "dispatches directly to module function" do
      comp =
        Port.request(TestQueries, :find_user, %{id: 42})
        |> Port.with_handler(%{TestQueries => :direct})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 42, name: "User 42"}} = result
    end
  end

  describe "request!/3" do
    test "unwraps {:ok, value} and returns value" do
      comp =
        Port.request!(TestQueries, :find_user, %{id: 42})
        |> Port.with_handler(%{TestQueries => :direct})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{id: 42, name: "User 42"} = result
    end

    test "dispatches Throw on {:error, reason}" do
      comp =
        Port.request!(TestQueries, :find_user_or_error, %{id: -1})
        |> Port.with_handler(%{TestQueries => :direct})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:not_found, :user, -1}} = result
    end

    test "unwraps list results" do
      comp =
        Port.request!(TestQueries, :list_users, %{limit: 3})
        |> Port.with_handler(%{TestQueries => :direct})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert [%{id: 1}, %{id: 2}, %{id: 3}] = result
    end

    test "works with test handler stubs" do
      responses = %{
        Port.key(TestQueries, :find_user, %{id: 999}) => {:ok, %{id: 999, name: "Stubbed"}}
      }

      comp =
        Port.request!(TestQueries, :find_user, %{id: 999})
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %{id: 999, name: "Stubbed"} = result
    end

    test "throws on stubbed error response" do
      responses = %{
        Port.key(TestQueries, :find_user, %{id: 404}) => {:error, :user_not_found}
      }

      comp =
        Port.request!(TestQueries, :find_user, %{id: 404})
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: :user_not_found} = result
    end
  end

  describe "with_handler/2 - function resolver" do
    test "dispatches to anonymous function" do
      resolver = fn _mod, _name, %{id: id} ->
        {:ok, %{id: id, name: "Custom #{id}"}}
      end

      comp =
        Port.request(TestQueries, :find_user, %{id: 99})
        |> Port.with_handler(%{TestQueries => resolver})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 99, name: "Custom 99"}} = result
    end
  end

  describe "with_handler/2 - {module, function} resolver" do
    defmodule MFResolver do
      def resolve(_mod, _name, %{id: id}) do
        {:ok, %{id: id, name: "MF #{id}"}}
      end
    end

    test "dispatches to module/function tuple" do
      comp =
        Port.request(TestQueries, :find_user, %{id: 77})
        |> Port.with_handler(%{TestQueries => {MFResolver, :resolve}})

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 77, name: "MF 77"}} = result
    end
  end

  describe "with_handler/2 - module resolver" do
    test "dispatches to module with handle_port/3" do
      comp =
        Port.request(TestQueries, :find_user, %{id: 55})
        |> Port.with_handler(%{TestQueries => TestPortHandler})

      {result, _env} = Comp.run(comp)
      assert {:ok, {:handled, {:ok, %{id: 55, name: "User 55"}}}} = result
    end
  end

  describe "with_handler/2 - error handling" do
    test "throws on unknown module" do
      comp =
        Port.request(UnknownModule, :some_request, %{})
        |> Port.with_handler(%{TestQueries => :direct})
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:unknown_port_module, UnknownModule}} = result
    end

    test "throws on request exception" do
      comp =
        Port.request(TestQueries, :failing_request, %{})
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
        Port.key(TestQueries, :find_user, %{id: 123}) => {:ok, %{id: 123, name: "Stubbed Alice"}}
      }

      comp =
        Port.request(TestQueries, :find_user, %{id: 123})
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert {:ok, %{id: 123, name: "Stubbed Alice"}} = result
    end

    test "throws on missing stub" do
      responses = %{
        Port.key(TestQueries, :find_user, %{id: 123}) => {:ok, %{id: 123, name: "Alice"}}
      }

      comp =
        Port.request(TestQueries, :find_user, %{id: 999})
        |> Port.with_test_handler(responses)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)
      assert %ThrowResult{error: {:port_not_stubbed, {TestQueries, :find_user, _}}} = result
    end

    test "can stub error responses" do
      responses = %{
        Port.key(TestQueries, :find_user, %{id: 404}) => {:error, :not_found}
      }

      comp =
        Port.request(TestQueries, :find_user, %{id: 404})
        |> Port.with_test_handler(responses)

      {result, _env} = Comp.run(comp)
      assert {:error, :not_found} = result
    end
  end

  describe "key/3" do
    test "produces same key for equivalent params regardless of key order" do
      key1 = Port.key(TestQueries, :find, %{a: 1, b: 2})
      key2 = Port.key(TestQueries, :find, %{b: 2, a: 1})
      assert key1 == key2
    end

    test "different params produce different keys" do
      key1 = Port.key(TestQueries, :find, %{id: 1})
      key2 = Port.key(TestQueries, :find, %{id: 2})
      assert key1 != key2
    end

    test "handles nested maps" do
      key1 = Port.key(TestQueries, :find, %{filter: %{a: 1, b: 2}})
      key2 = Port.key(TestQueries, :find, %{filter: %{b: 2, a: 1}})
      assert key1 == key2
    end

    test "handles structs" do
      # Use URI struct as a test case
      key1 = Port.key(TestQueries, :find, %URI{host: "example.com", port: 80})
      key2 = Port.key(TestQueries, :find, %URI{host: "example.com", port: 80})
      assert key1 == key2
    end

    test "handles lists" do
      key1 = Port.key(TestQueries, :find, %{ids: [1, 2, 3]})
      key2 = Port.key(TestQueries, :find, %{ids: [1, 2, 3]})
      assert key1 == key2
    end

    test "handles tuples" do
      key1 = Port.key(TestQueries, :find, %{range: {1, 10}})
      key2 = Port.key(TestQueries, :find, %{range: {1, 10}})
      assert key1 == key2
    end
  end

  describe "composition" do
    test "multiple requests in sequence using request!" do
      responses = %{
        Port.key(TestQueries, :find_user, %{id: 1}) => {:ok, %{id: 1, name: "Alice"}},
        Port.key(TestQueries, :find_user, %{id: 2}) => {:ok, %{id: 2, name: "Bob"}}
      }

      comp =
        Comp.bind(Port.request!(TestQueries, :find_user, %{id: 1}), fn user1 ->
          Comp.bind(Port.request!(TestQueries, :find_user, %{id: 2}), fn user2 ->
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
        Port.key(TestQueries, :find_user, %{id: 1}) => {:ok, %{id: 1, name: "Alice"}},
        Port.key(TestQueries, :find_user, %{id: 2}) => {:error, :not_found}
      }

      comp =
        Comp.bind(Port.request(TestQueries, :find_user, %{id: 1}), fn result1 ->
          Comp.bind(Port.request(TestQueries, :find_user, %{id: 2}), fn result2 ->
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
        Port.key(TestQueries, :find_user, %{id: 1}) => {:ok, %{id: 1, name: "Alice"}}
      }

      comp =
        Comp.bind(Port.request!(TestQueries, :find_user, %{id: 1}), fn user ->
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
end
