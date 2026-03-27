defmodule Skuld.Effects.Port.RepoTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Port
  alias Skuld.Effects.Port.Repo
  alias Skuld.Effects.Throw

  # -------------------------------------------------------------------
  # Test Schema
  # -------------------------------------------------------------------

  defmodule TestUser do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      field(:email, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name, :email])
    end
  end

  # -------------------------------------------------------------------
  # Contract Tests
  # -------------------------------------------------------------------

  describe "Port.Repo contract" do
    test "generates Plain behaviour module" do
      callbacks =
        Repo.Plain.behaviour_info(:callbacks)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert :insert in callbacks
      assert :update in callbacks
      assert :delete in callbacks
      assert :update_all in callbacks
      assert :delete_all in callbacks
      assert :get in callbacks
      assert :get! in callbacks
      assert :get_by in callbacks
      assert :get_by! in callbacks
      assert :one in callbacks
      assert :one! in callbacks
      assert :all in callbacks
      assert :exists? in callbacks
      assert :aggregate in callbacks
    end

    test "generates Effectful behaviour module" do
      callbacks =
        Repo.Effectful.behaviour_info(:callbacks)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert :insert in callbacks
      assert :update in callbacks
      assert :delete in callbacks
      assert :get in callbacks
      assert :all in callbacks
    end

    test "generates bang variants for write operations" do
      fns = Repo.__info__(:functions) |> Map.new()

      # Auto-generated bangs from {:ok, T} return types
      assert Map.has_key?(fns, :insert!)
      assert Map.has_key?(fns, :update!)
      assert Map.has_key?(fns, :delete!)
    end

    test "read bang operations are defined as separate ports (not auto-generated)" do
      ops = Repo.__port_operations__() |> Enum.map(& &1.name)

      # These are declared as defport with bang: false
      assert :get! in ops
      assert :get_by! in ops
      assert :one! in ops
    end

    test "__port_operations__ lists all operations" do
      ops = Repo.__port_operations__()

      assert length(ops) == 14

      op_names = Enum.map(ops, & &1.name) |> Enum.sort()

      assert op_names == [
               :aggregate,
               :all,
               :delete,
               :delete_all,
               :exists?,
               :get,
               :get!,
               :get_by,
               :get_by!,
               :insert,
               :one,
               :one!,
               :update,
               :update_all
             ]
    end

    test "caller functions return computations" do
      changeset = TestUser.changeset(%{name: "Alice"})

      # Each caller should return a computation (function)
      assert is_function(Repo.insert(changeset))
      assert is_function(Repo.get(TestUser, 1))
      assert is_function(Repo.all(TestUser))
    end

    test "key helpers generate keys for test stubs" do
      changeset = TestUser.changeset(%{name: "Alice"})

      key = Repo.key(:insert, changeset)
      assert {Repo, :insert, _} = key

      key2 = Repo.key(:get, TestUser, 42)
      assert {Repo, :get, _} = key2
    end
  end

  # -------------------------------------------------------------------
  # Ecto Executor Tests
  # -------------------------------------------------------------------

  defmodule MockRepo do
    def insert(cs), do: {:ok, Ecto.Changeset.apply_changes(cs)}
    def update(cs), do: {:ok, Ecto.Changeset.apply_changes(cs)}
    def delete(record), do: {:ok, record}
    def update_all(_q, _u, _o), do: {3, nil}
    def delete_all(_q, _o), do: {5, nil}
    def get(_q, id), do: %TestUser{id: id, name: "found"}
    def get!(_q, id), do: %TestUser{id: id, name: "found!"}
    def get_by(_q, clauses), do: %TestUser{id: 1, name: clauses[:name]}
    def get_by!(_q, clauses), do: %TestUser{id: 1, name: clauses[:name]}
    def one(_q), do: %TestUser{id: 1, name: "one"}
    def one!(_q), do: %TestUser{id: 1, name: "one!"}
    def all(_q), do: [%TestUser{id: 1}, %TestUser{id: 2}]
    def exists?(_q), do: true
    def aggregate(_q, _agg, _f), do: 42
  end

  defmodule TestRepoPort do
    use Skuld.Effects.Port.Repo.Ecto, repo: MockRepo
  end

  describe "Port.Repo.Ecto executor" do
    test "insert delegates to Repo" do
      cs = TestUser.changeset(%{name: "Alice"})

      result =
        Repo.insert(cs)
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Comp.run!()

      assert {:ok, %TestUser{name: "Alice"}} = result
    end

    test "update delegates to Repo" do
      cs = TestUser.changeset(%TestUser{id: 1, name: "old"}, %{name: "new"})

      result =
        Repo.update(cs)
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Comp.run!()

      assert {:ok, %TestUser{name: "new"}} = result
    end

    test "delete delegates to Repo" do
      record = %TestUser{id: 1, name: "Alice"}

      result =
        Repo.delete(record)
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Comp.run!()

      assert {:ok, ^record} = result
    end

    test "get delegates to Repo" do
      result =
        Repo.get(TestUser, 42)
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Comp.run!()

      assert %TestUser{id: 42, name: "found"} = result
    end

    test "all delegates to Repo" do
      result =
        Repo.all(TestUser)
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Comp.run!()

      assert [%TestUser{id: 1}, %TestUser{id: 2}] = result
    end

    test "exists? delegates to Repo" do
      result =
        Repo.exists?(TestUser)
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Comp.run!()

      assert result == true
    end

    test "aggregate delegates to Repo" do
      result =
        Repo.aggregate(TestUser, :count, :id)
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Comp.run!()

      assert result == 42
    end

    test "update_all delegates to Repo" do
      result =
        Repo.update_all(TestUser, [set: [name: "bulk"]], [])
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Comp.run!()

      assert {3, nil} = result
    end

    test "delete_all delegates to Repo" do
      result =
        Repo.delete_all(TestUser, [])
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Comp.run!()

      assert {5, nil} = result
    end

    test "bang variant unwraps {:ok, value}" do
      cs = TestUser.changeset(%{name: "Alice"})

      result =
        Repo.insert!(cs)
        |> Port.with_handler(%{Repo => TestRepoPort})
        |> Throw.with_handler()
        |> Comp.run!()

      assert %TestUser{name: "Alice"} = result
    end
  end

  # -------------------------------------------------------------------
  # Test Executor Tests
  # -------------------------------------------------------------------

  describe "Port.Repo.Test executor" do
    test "insert applies changeset and logs operation" do
      cs = TestUser.changeset(%{name: "Alice"})

      {user, log} =
        comp do
          result <- Repo.insert(cs)
          result
        end
        |> Repo.Test.with_handler(output: fn r, log -> {r, log} end)
        |> Comp.run!()

      assert {:ok, %TestUser{name: "Alice"}} = user
      assert [{:insert, [^cs], {:ok, %TestUser{name: "Alice"}}}] = log
    end

    test "update applies changeset and logs operation" do
      cs = TestUser.changeset(%TestUser{id: 1, name: "old"}, %{name: "new"})

      {result, log} =
        comp do
          result <- Repo.update(cs)
          result
        end
        |> Repo.Test.with_handler(output: fn r, log -> {r, log} end)
        |> Comp.run!()

      assert {:ok, %TestUser{id: 1, name: "new"}} = result
      assert [{:update, [^cs], {:ok, %TestUser{id: 1, name: "new"}}}] = log
    end

    test "delete logs operation and returns the record" do
      record = %TestUser{id: 1, name: "Alice"}

      {result, log} =
        comp do
          result <- Repo.delete(record)
          result
        end
        |> Repo.Test.with_handler(output: fn r, log -> {r, log} end)
        |> Comp.run!()

      assert {:ok, ^record} = result
      assert [{:delete, [^record], {:ok, ^record}}] = log
    end

    test "bang variant unwraps and logs" do
      cs = TestUser.changeset(%{name: "Alice"})

      {user, log} =
        comp do
          user <- Repo.insert!(cs)
          user
        end
        |> Repo.Test.with_handler(output: fn r, log -> {r, log} end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert %TestUser{name: "Alice"} = user
      assert [{:insert, [^cs], {:ok, %TestUser{name: "Alice"}}}] = log
    end

    test "multiple operations accumulate in order" do
      cs1 = TestUser.changeset(%{name: "Alice"})
      cs2 = TestUser.changeset(%{name: "Bob"})

      {_result, log} =
        comp do
          alice <- Repo.insert!(cs1)
          bob <- Repo.insert!(cs2)
          _ <- Repo.get(TestUser, 42)
          {alice, bob}
        end
        |> Repo.Test.with_handler(output: fn r, log -> {r, log} end)
        |> Throw.with_handler()
        |> Comp.run!()

      assert [
               {:insert, _, {:ok, %TestUser{name: "Alice"}}},
               {:insert, _, {:ok, %TestUser{name: "Bob"}}},
               {:get, [TestUser, 42], nil}
             ] = log
    end

    test "read operations return sensible defaults" do
      {results, log} =
        comp do
          a <- Repo.get(TestUser, 1)
          b <- Repo.get_by(TestUser, name: "Alice")
          c <- Repo.one(TestUser)
          d <- Repo.all(TestUser)
          e <- Repo.exists?(TestUser)
          f <- Repo.aggregate(TestUser, :count, :id)
          {a, b, c, d, e, f}
        end
        |> Repo.Test.with_handler(output: fn r, log -> {r, log} end)
        |> Comp.run!()

      assert {nil, nil, nil, [], false, nil} = results
      assert length(log) == 6
    end

    test "bulk operations log with default values" do
      {results, log} =
        comp do
          a <- Repo.update_all(TestUser, [set: [name: "bulk"]], [])
          b <- Repo.delete_all(TestUser, [])
          {a, b}
        end
        |> Repo.Test.with_handler(output: fn r, log -> {r, log} end)
        |> Comp.run!()

      assert {{0, nil}, {0, nil}} = results

      assert [
               {:update_all, [TestUser, [set: [name: "bulk"]], []], {0, nil}},
               {:delete_all, [TestUser, []], {0, nil}}
             ] = log
    end

    test "without output option, log is discarded" do
      cs = TestUser.changeset(%{name: "Alice"})

      result =
        comp do
          user <- Repo.insert!(cs)
          user
        end
        |> Repo.Test.with_handler()
        |> Throw.with_handler()
        |> Comp.run!()

      assert %TestUser{name: "Alice"} = result
    end

    test "composes with other Port contracts" do
      defmodule OtherContract do
        use Skuld.Effects.Port.Contract

        defport(do_thing(x :: term()) :: {:ok, term()} | {:error, term()})
      end

      defmodule OtherImpl do
        @behaviour OtherContract.Plain

        @impl true
        def do_thing(x), do: {:ok, {:did, x}}
      end

      cs = TestUser.changeset(%{name: "Alice"})

      {result, log} =
        comp do
          user <- Repo.insert!(cs)
          thing <- OtherContract.do_thing!(user)
          thing
        end
        |> Repo.Test.with_handler(
          registry: %{OtherContract => OtherImpl},
          output: fn r, log -> {r, log} end
        )
        |> Throw.with_handler()
        |> Comp.run!()

      assert {:did, %TestUser{name: "Alice"}} = result
      # Only Repo operations appear in the log
      assert [{:insert, _, _}] = log
    end
  end
end
