defmodule Skuld.Effects.EctoPersistTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.EctoPersist
  alias Skuld.Effects.EctoPersist.EctoEvent
  alias Skuld.Effects.Throw

  # Test schema
  defmodule TestUser do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      field(:email, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name, :email])
      |> Ecto.Changeset.validate_required([:name])
    end
  end

  # Mock Repo for testing
  defmodule MockRepo do
    def insert(%Ecto.Changeset{valid?: true} = cs, _opts) do
      struct = Ecto.Changeset.apply_changes(cs)
      {:ok, %{struct | id: :rand.uniform(1000)}}
    end

    def insert(%Ecto.Changeset{valid?: false} = cs, _opts) do
      {:error, cs}
    end

    def update(%Ecto.Changeset{valid?: true} = cs, _opts) do
      {:ok, Ecto.Changeset.apply_changes(cs)}
    end

    def update(%Ecto.Changeset{valid?: false} = cs, _opts) do
      {:error, cs}
    end

    def insert_or_update(%Ecto.Changeset{valid?: true} = cs, _opts) do
      struct = Ecto.Changeset.apply_changes(cs)
      {:ok, %{struct | id: struct.id || :rand.uniform(1000)}}
    end

    def insert_or_update(%Ecto.Changeset{valid?: false} = cs, _opts) do
      {:error, cs}
    end

    def delete(input, _opts) do
      struct =
        case input do
          %Ecto.Changeset{} = cs -> Ecto.Changeset.apply_changes(cs)
          %{__struct__: _} = s -> s
        end

      {:ok, struct}
    end

    def insert_all(schema, entries, opts) do
      returning = Keyword.get(opts, :returning, false)

      structs =
        if returning do
          Enum.map(entries, fn entry ->
            struct(schema, Map.put(entry, :id, :rand.uniform(1000)))
          end)
        else
          nil
        end

      {length(entries), structs}
    end

    def update_all(_query, _opts) do
      {1, nil}
    end
  end

  describe "single operations" do
    test "insert with changeset" do
      cs = TestUser.changeset(%{name: "Alice", email: "alice@test.com"})

      computation =
        comp do
          user <- EctoPersist.insert(cs)
          return(user)
        end
        |> EctoPersist.with_handler(MockRepo)

      user = Comp.run!(computation)
      assert user.name == "Alice"
      assert user.email == "alice@test.com"
      assert user.id != nil
    end

    test "insert with EctoEvent" do
      cs = TestUser.changeset(%{name: "Bob"})
      event = EctoEvent.insert(cs)

      computation =
        comp do
          user <- EctoPersist.insert(event)
          return(user)
        end
        |> EctoPersist.with_handler(MockRepo)

      user = Comp.run!(computation)
      assert user.name == "Bob"
    end

    test "insert with invalid changeset throws" do
      # Missing required :name field
      cs = TestUser.changeset(%{email: "invalid@test.com"})

      computation =
        comp do
          user <- EctoPersist.insert(cs)
          return(user)
        end
        |> EctoPersist.with_handler(MockRepo)
        |> Throw.with_handler()

      {result, _env} = Comp.run(computation)
      assert %Comp.Throw{error: {:invalid_changeset, _}} = result
    end

    test "insert with invalid changeset can be caught" do
      cs = TestUser.changeset(%{email: "invalid@test.com"})

      computation =
        comp do
          user <- EctoPersist.insert(cs)
          return({:ok, user})
        catch
          {:invalid_changeset, changeset} -> return({:error, changeset})
        end
        |> EctoPersist.with_handler(MockRepo)
        |> Throw.with_handler()

      {:error, changeset} = Comp.run!(computation)
      assert changeset.valid? == false
    end

    test "update with changeset" do
      user = %TestUser{id: 1, name: "Old", email: "old@test.com"}
      cs = TestUser.changeset(user, %{name: "New"})

      computation =
        comp do
          updated <- EctoPersist.update(cs)
          return(updated)
        end
        |> EctoPersist.with_handler(MockRepo)

      updated = Comp.run!(computation)
      assert updated.name == "New"
      assert updated.id == 1
    end

    test "upsert with changeset" do
      cs = TestUser.changeset(%{name: "Upserted"})

      computation =
        comp do
          user <- EctoPersist.upsert(cs)
          return(user)
        end
        |> EctoPersist.with_handler(MockRepo)

      user = Comp.run!(computation)
      assert user.name == "Upserted"
    end

    test "delete with struct" do
      user = %TestUser{id: 1, name: "ToDelete"}

      computation =
        comp do
          result <- EctoPersist.delete(user)
          return(result)
        end
        |> EctoPersist.with_handler(MockRepo)

      {:ok, deleted} = Comp.run!(computation)
      assert deleted.id == 1
    end

    test "delete with EctoEvent" do
      user = %TestUser{id: 1, name: "ToDelete"}
      cs = Ecto.Changeset.change(user)
      event = EctoEvent.delete(cs)

      computation =
        comp do
          result <- EctoPersist.delete(event)
          return(result)
        end
        |> EctoPersist.with_handler(MockRepo)

      {:ok, deleted} = Comp.run!(computation)
      assert deleted.id == 1
    end
  end

  describe "bulk operations" do
    test "insert_all with changesets" do
      changesets = [
        TestUser.changeset(%{name: "User1"}),
        TestUser.changeset(%{name: "User2"}),
        TestUser.changeset(%{name: "User3"})
      ]

      computation =
        comp do
          result <- EctoPersist.insert_all(TestUser, changesets)
          return(result)
        end
        |> EctoPersist.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 3
    end

    test "insert_all with returning option" do
      changesets = [
        TestUser.changeset(%{name: "User1"}),
        TestUser.changeset(%{name: "User2"})
      ]

      computation =
        comp do
          result <- EctoPersist.insert_all(TestUser, changesets, returning: true)
          return(result)
        end
        |> EctoPersist.with_handler(MockRepo)

      {count, users} = Comp.run!(computation)
      assert count == 2
      assert length(users) == 2
      assert Enum.all?(users, &(&1.id != nil))
    end

    test "insert_all with EctoEvents" do
      events = [
        EctoEvent.insert(TestUser.changeset(%{name: "User1"})),
        EctoEvent.insert(TestUser.changeset(%{name: "User2"}))
      ]

      computation =
        comp do
          result <- EctoPersist.insert_all(TestUser, events)
          return(result)
        end
        |> EctoPersist.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 2
    end

    test "insert_all with maps" do
      maps = [
        %{name: "User1"},
        %{name: "User2"}
      ]

      computation =
        comp do
          result <- EctoPersist.insert_all(TestUser, maps)
          return(result)
        end
        |> EctoPersist.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 2
    end

    test "insert_all with empty list" do
      computation =
        comp do
          result <- EctoPersist.insert_all(TestUser, [])
          return(result)
        end
        |> EctoPersist.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 0
    end

    test "delete_all with structs" do
      users = [
        %TestUser{id: 1, name: "User1"},
        %TestUser{id: 2, name: "User2"}
      ]

      computation =
        comp do
          result <- EctoPersist.delete_all(TestUser, users)
          return(result)
        end
        |> EctoPersist.with_handler(MockRepo)

      {count, nil} = Comp.run!(computation)
      assert count == 2
    end
  end

  describe "schema validation" do
    defmodule OtherSchema do
      use Ecto.Schema

      schema "other" do
        field(:value, :string)
      end

      def changeset(other \\ %__MODULE__{}, attrs) do
        Ecto.Changeset.cast(other, attrs, [:value])
      end
    end

    test "insert_all with mismatched schema throws" do
      # Create changeset for different schema
      other_cs = OtherSchema.changeset(%{value: "test"})

      computation =
        comp do
          result <- EctoPersist.insert_all(TestUser, [other_cs])
          return(result)
        end
        |> EctoPersist.with_handler(MockRepo)
        |> Throw.with_handler()

      {result, _env} = Comp.run(computation)
      assert %Comp.Throw{error: {:schema_mismatch, _}} = result
    end
  end

  describe "handler" do
    test "raises when handler not installed" do
      cs = TestUser.changeset(%{name: "Alice"})

      computation =
        comp do
          user <- EctoPersist.insert(cs)
          return(user)
        end

      assert_raise RuntimeError, ~r/handler not installed/, fn ->
        Comp.run!(computation)
      end
    end
  end
end
