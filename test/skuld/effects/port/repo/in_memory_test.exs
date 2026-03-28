defmodule Skuld.Effects.Port.Repo.InMemoryTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Port
  alias Skuld.Effects.Port.Repo
  alias Skuld.Effects.Port.Repo.InMemory
  alias Skuld.Effects.Throw

  # -------------------------------------------------------------------
  # Test Schema
  # -------------------------------------------------------------------

  defmodule User do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name, :email, :age])
    end
  end

  defmodule Post do
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      field(:body, :string)
    end

    def changeset(post \\ %__MODULE__{}, attrs) do
      post
      |> Ecto.Changeset.cast(attrs, [:title, :body])
    end
  end

  # -------------------------------------------------------------------
  # Helper
  # -------------------------------------------------------------------

  defp with_in_memory(comp, initial \\ %{}, opts \\ []) do
    InMemory.with_handler(comp, initial, opts)
  end

  defp with_store_output(comp, initial \\ %{}) do
    InMemory.with_handler(comp, initial,
      output: fn result, state -> {result, state.handler_state} end
    )
  end

  # -------------------------------------------------------------------
  # seed/1
  # -------------------------------------------------------------------

  describe "seed/1" do
    test "converts list of structs to state map" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}

      store = InMemory.seed([alice, bob])

      assert %{
               {User, 1} => ^alice,
               {User, 2} => ^bob
             } = store
    end

    test "handles multiple schema types" do
      user = %User{id: 1, name: "Alice"}
      post = %Post{id: 1, title: "Hello"}

      store = InMemory.seed([user, post])

      assert %{
               {User, 1} => ^user,
               {Post, 1} => ^post
             } = store
    end

    test "empty list returns empty map" do
      assert %{} = InMemory.seed([])
    end
  end

  # -------------------------------------------------------------------
  # Write Operations
  # -------------------------------------------------------------------

  describe "insert" do
    test "inserts a record and returns {:ok, struct}" do
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})

      result =
        Repo.insert(cs)
        |> with_in_memory()
        |> Comp.run!()

      assert {:ok, %User{name: "Alice", email: "alice@example.com"}} = result
    end

    test "auto-assigns id when nil" do
      cs = User.changeset(%{name: "Alice"})

      {result, store} =
        Repo.insert(cs)
        |> with_store_output()
        |> Comp.run!()

      assert {:ok, %User{id: 1, name: "Alice"}} = result
      assert %{{User, 1} => %User{id: 1, name: "Alice"}} = store
    end

    test "preserves explicit id" do
      cs = User.changeset(%User{id: 42}, %{name: "Alice"})

      {result, store} =
        Repo.insert(cs)
        |> with_store_output()
        |> Comp.run!()

      assert {:ok, %User{id: 42, name: "Alice"}} = result
      assert %{{User, 42} => %User{id: 42}} = store
    end

    test "auto-id increments based on existing records" do
      initial = InMemory.seed([%User{id: 5, name: "Existing"}])

      {result, _store} =
        comp do
          r <- Repo.insert(User.changeset(%{name: "New"}))
          r
        end
        |> with_store_output(initial)
        |> Comp.run!()

      assert {:ok, %User{id: 6, name: "New"}} = result
    end

    test "insert! unwraps the result" do
      cs = User.changeset(%{name: "Alice"})

      result =
        Repo.insert!(cs)
        |> with_in_memory()
        |> Throw.with_handler()
        |> Comp.run!()

      assert %User{name: "Alice"} = result
    end
  end

  describe "update" do
    test "updates an existing record" do
      initial = InMemory.seed([%User{id: 1, name: "Alice", email: "old@example.com"}])
      cs = User.changeset(%User{id: 1, name: "Alice"}, %{email: "new@example.com"})

      {result, store} =
        Repo.update(cs)
        |> with_store_output(initial)
        |> Comp.run!()

      assert {:ok, %User{id: 1, email: "new@example.com"}} = result
      assert %{{User, 1} => %User{id: 1, email: "new@example.com"}} = store
    end

    test "update! unwraps the result" do
      initial = InMemory.seed([%User{id: 1, name: "Alice"}])
      cs = User.changeset(%User{id: 1, name: "Alice"}, %{name: "Bob"})

      result =
        Repo.update!(cs)
        |> InMemory.with_handler(initial)
        |> Throw.with_handler()
        |> Comp.run!()

      assert %User{id: 1, name: "Bob"} = result
    end
  end

  describe "delete" do
    test "removes record from store" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.seed([alice])

      {result, store} =
        Repo.delete(alice)
        |> with_store_output(initial)
        |> Comp.run!()

      assert {:ok, ^alice} = result
      assert store == %{}
    end

    test "delete! unwraps the result" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.seed([alice])

      result =
        Repo.delete!(alice)
        |> InMemory.with_handler(initial)
        |> Throw.with_handler()
        |> Comp.run!()

      assert ^alice = result
    end
  end

  # -------------------------------------------------------------------
  # Read Operations
  # -------------------------------------------------------------------

  describe "get" do
    test "returns record when found" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.seed([alice])

      result =
        Repo.get(User, 1)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert ^alice = result
    end

    test "returns nil when not found" do
      result =
        Repo.get(User, 999)
        |> with_in_memory()
        |> Comp.run!()

      assert result == nil
    end
  end

  describe "get!" do
    test "returns record when found" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.seed([alice])

      result =
        Repo.get!(User, 1)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert ^alice = result
    end

    test "returns nil when not found" do
      result =
        Repo.get!(User, 999)
        |> with_in_memory()
        |> Comp.run!()

      assert result == nil
    end
  end

  describe "get_by" do
    test "finds record matching clauses" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}
      bob = %User{id: 2, name: "Bob", email: "bob@example.com"}
      initial = InMemory.seed([alice, bob])

      result =
        Repo.get_by(User, name: "Bob")
        |> with_in_memory(initial)
        |> Comp.run!()

      assert ^bob = result
    end

    test "returns nil when no match" do
      initial = InMemory.seed([%User{id: 1, name: "Alice"}])

      result =
        Repo.get_by(User, name: "Nobody")
        |> with_in_memory(initial)
        |> Comp.run!()

      assert result == nil
    end

    test "matches multiple clauses" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}
      initial = InMemory.seed([alice])

      result =
        Repo.get_by(User, name: "Alice", email: "alice@example.com")
        |> with_in_memory(initial)
        |> Comp.run!()

      assert ^alice = result
    end

    test "accepts map clauses" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.seed([alice])

      result =
        Repo.get_by(User, %{name: "Alice"})
        |> with_in_memory(initial)
        |> Comp.run!()

      assert ^alice = result
    end
  end

  describe "one" do
    test "returns a record when schema has records" do
      alice = %User{id: 1, name: "Alice"}
      initial = InMemory.seed([alice])

      result =
        Repo.one(User)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert %User{} = result
    end

    test "returns nil when no records" do
      result =
        Repo.one(User)
        |> with_in_memory()
        |> Comp.run!()

      assert result == nil
    end
  end

  describe "all" do
    test "returns all records of a schema" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}
      post = %Post{id: 1, title: "Hello"}
      initial = InMemory.seed([alice, bob, post])

      result =
        Repo.all(User)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert length(result) == 2
      assert Enum.all?(result, &match?(%User{}, &1))
    end

    test "returns empty list when no records" do
      result =
        Repo.all(User)
        |> with_in_memory()
        |> Comp.run!()

      assert result == []
    end
  end

  describe "exists?" do
    test "returns true when records exist" do
      initial = InMemory.seed([%User{id: 1, name: "Alice"}])

      result =
        Repo.exists?(User)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert result == true
    end

    test "returns false when no records" do
      result =
        Repo.exists?(User)
        |> with_in_memory()
        |> Comp.run!()

      assert result == false
    end
  end

  describe "aggregate" do
    test "count returns number of records" do
      initial =
        InMemory.seed([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"},
          %User{id: 3, name: "Charlie"}
        ])

      result =
        Repo.aggregate(User, :count, :id)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert result == 3
    end

    test "count returns 0 for empty" do
      result =
        Repo.aggregate(User, :count, :id)
        |> with_in_memory()
        |> Comp.run!()

      assert result == 0
    end

    test "sum aggregates field values" do
      initial =
        InMemory.seed([
          %User{id: 1, name: "Alice", age: 30},
          %User{id: 2, name: "Bob", age: 25}
        ])

      result =
        Repo.aggregate(User, :sum, :age)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert result == 55
    end

    test "min returns minimum value" do
      initial =
        InMemory.seed([
          %User{id: 1, name: "Alice", age: 30},
          %User{id: 2, name: "Bob", age: 25}
        ])

      result =
        Repo.aggregate(User, :min, :age)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert result == 25
    end

    test "max returns maximum value" do
      initial =
        InMemory.seed([
          %User{id: 1, name: "Alice", age: 30},
          %User{id: 2, name: "Bob", age: 25}
        ])

      result =
        Repo.aggregate(User, :max, :age)
        |> with_in_memory(initial)
        |> Comp.run!()

      assert result == 30
    end
  end

  # -------------------------------------------------------------------
  # Bulk Operations
  # -------------------------------------------------------------------

  describe "delete_all" do
    test "removes all records of the given schema" do
      initial =
        InMemory.seed([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"},
          %Post{id: 1, title: "Hello"}
        ])

      {result, store} =
        Repo.delete_all(User, [])
        |> with_store_output(initial)
        |> Comp.run!()

      assert {2, nil} = result
      # Post remains, users deleted
      assert map_size(store) == 1
      assert Map.has_key?(store, {Post, 1})
    end
  end

  describe "update_all" do
    test "returns {0, nil} (not supported)" do
      initial = InMemory.seed([%User{id: 1, name: "Alice"}])

      result =
        Repo.update_all(User, [set: [name: "bulk"]], [])
        |> with_in_memory(initial)
        |> Comp.run!()

      assert {0, nil} = result
    end
  end

  # -------------------------------------------------------------------
  # Read-after-Write Consistency
  # -------------------------------------------------------------------

  describe "read-after-write consistency" do
    test "insert then get returns the same record" do
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})

      result =
        comp do
          {:ok, user} <- Repo.insert(cs)
          found <- Repo.get(User, user.id)
          {user, found}
        end
        |> with_in_memory()
        |> Comp.run!()

      {inserted, found} = result
      assert inserted == found
      assert %User{name: "Alice", email: "alice@example.com"} = found
    end

    test "insert then get_by returns the same record" do
      cs = User.changeset(%{name: "Alice"})

      result =
        comp do
          {:ok, user} <- Repo.insert(cs)
          found <- Repo.get_by(User, name: "Alice")
          {user, found}
        end
        |> with_in_memory()
        |> Comp.run!()

      {inserted, found} = result
      assert inserted == found
    end

    test "insert then all includes the record" do
      cs1 = User.changeset(%{name: "Alice"})
      cs2 = User.changeset(%{name: "Bob"})

      result =
        comp do
          _ <- Repo.insert(cs1)
          _ <- Repo.insert(cs2)
          Repo.all(User)
        end
        |> with_in_memory()
        |> Comp.run!()

      assert length(result) == 2
      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end

    test "insert then delete then get returns nil" do
      cs = User.changeset(%{name: "Alice"})

      result =
        comp do
          {:ok, user} <- Repo.insert(cs)
          _ <- Repo.delete(user)
          Repo.get(User, user.id)
        end
        |> with_in_memory()
        |> Comp.run!()

      assert result == nil
    end

    test "insert, update, then get returns updated record" do
      result =
        comp do
          {:ok, user} <- Repo.insert(User.changeset(%{name: "Alice"}))
          {:ok, updated} <- Repo.update(User.changeset(user, %{name: "Alicia"}))
          found <- Repo.get(User, user.id)
          {updated, found}
        end
        |> with_in_memory()
        |> Comp.run!()

      {updated, found} = result
      assert updated == found
      assert %User{name: "Alicia"} = found
    end

    test "insert affects exists? and aggregate" do
      cs = User.changeset(%{name: "Alice"})

      result =
        comp do
          exists_before <- Repo.exists?(User)
          count_before <- Repo.aggregate(User, :count, :id)
          _ <- Repo.insert(cs)
          exists_after <- Repo.exists?(User)
          count_after <- Repo.aggregate(User, :count, :id)
          {exists_before, count_before, exists_after, count_after}
        end
        |> with_in_memory()
        |> Comp.run!()

      assert {false, 0, true, 1} = result
    end
  end

  # -------------------------------------------------------------------
  # Seeded State
  # -------------------------------------------------------------------

  describe "seeded initial state" do
    test "seeded records are available immediately" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}
      initial = InMemory.seed([alice, bob])

      result =
        comp do
          a <- Repo.get(User, 1)
          b <- Repo.get(User, 2)
          {a, b}
        end
        |> with_in_memory(initial)
        |> Comp.run!()

      assert {^alice, ^bob} = result
    end

    test "can add to seeded state" do
      initial = InMemory.seed([%User{id: 1, name: "Alice"}])
      cs = User.changeset(%{name: "Bob"})

      result =
        comp do
          _ <- Repo.insert(cs)
          Repo.all(User)
        end
        |> with_in_memory(initial)
        |> Comp.run!()

      assert length(result) == 2
    end
  end

  # -------------------------------------------------------------------
  # Logging
  # -------------------------------------------------------------------

  describe "logging" do
    test "logs all operations" do
      cs = User.changeset(%{name: "Alice"})

      {_result, log} =
        comp do
          {:ok, user} <- Repo.insert(cs)
          _ <- Repo.get(User, user.id)
          Repo.all(User)
        end
        |> InMemory.with_handler(%{},
          log: true,
          output: fn result, state -> {result, state.log} end
        )
        |> Comp.run!()

      assert length(log) == 3

      assert [{Repo, :insert, _, {:ok, %User{}}}, {Repo, :get, _, %User{}}, {Repo, :all, _, _}] =
               log
    end
  end

  # -------------------------------------------------------------------
  # Composition with Other Effects
  # -------------------------------------------------------------------

  describe "composition" do
    test "composes with State effect" do
      alias Skuld.Effects.State

      initial = InMemory.seed([%User{id: 1, name: "Alice"}])

      result =
        comp do
          user <- Repo.get(User, 1)
          count <- State.get()
          _ <- State.put(count + 1)
          {user, count}
        end
        |> with_in_memory(initial)
        |> State.with_handler(0)
        |> Comp.run!()

      assert {%User{name: "Alice"}, 0} = result
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

      initial = InMemory.seed([%User{id: 1, name: "Alice"}])

      result =
        comp do
          user <- Repo.get(User, 1)
          thing <- OtherContract.do_thing!(user)
          thing
        end
        |> with_in_memory(initial)
        |> Port.with_handler(%{OtherContract => OtherImpl})
        |> Throw.with_handler()
        |> Comp.run!()

      assert {:did, %User{name: "Alice"}} = result
    end
  end

  # -------------------------------------------------------------------
  # Multiple Schema Types
  # -------------------------------------------------------------------

  describe "multiple schema types" do
    test "different schemas are independent" do
      result =
        comp do
          {:ok, user} <- Repo.insert(User.changeset(%{name: "Alice"}))
          {:ok, post} <- Repo.insert(Post.changeset(%{title: "Hello"}))
          users <- Repo.all(User)
          posts <- Repo.all(Post)
          {user, post, users, posts}
        end
        |> with_in_memory()
        |> Comp.run!()

      {_user, _post, users, posts} = result
      assert length(users) == 1
      assert length(posts) == 1
      assert [%User{name: "Alice"}] = users
      assert [%Post{title: "Hello"}] = posts
    end

    test "delete_all only affects target schema" do
      initial =
        InMemory.seed([
          %User{id: 1, name: "Alice"},
          %Post{id: 1, title: "Hello"}
        ])

      {result, store} =
        Repo.delete_all(User, [])
        |> with_store_output(initial)
        |> Comp.run!()

      assert {1, nil} = result
      assert map_size(store) == 1
      assert Map.has_key?(store, {Post, 1})
    end
  end
end
