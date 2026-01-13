defmodule Skuld.Effects.ChangesetPersist.TestTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax
  alias Skuld.Comp
  alias Skuld.Effects.ChangesetPersist

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

  describe "with_handler/2" do
    test "records insert calls and returns handler result" do
      changeset = TestUser.changeset(%TestUser{id: 1}, %{name: "Test"})

      {result, calls} =
        comp do
          user <- ChangesetPersist.insert(changeset)
          return(user)
        end
        |> ChangesetPersist.Test.with_handler(fn
          %ChangesetPersist.Insert{input: cs} ->
            Ecto.Changeset.apply_changes(cs) |> Map.put(:id, 42)
        end)
        |> Comp.run!()

      assert result.id == 42
      assert result.name == "Test"
      assert [{:insert, ^changeset}] = calls
    end

    test "records update calls" do
      user = %TestUser{id: 1, name: "Old"}
      changeset = TestUser.changeset(user, %{name: "New"})

      {result, calls} =
        comp do
          updated <- ChangesetPersist.update(changeset)
          return(updated)
        end
        |> ChangesetPersist.Test.with_handler(fn
          %ChangesetPersist.Update{input: cs} -> Ecto.Changeset.apply_changes(cs)
        end)
        |> Comp.run!()

      assert result.name == "New"
      assert [{:update, ^changeset}] = calls
    end

    test "records delete calls" do
      user = %TestUser{id: 1, name: "To Delete"}

      {result, calls} =
        comp do
          deleted <- ChangesetPersist.delete(user)
          return(deleted)
        end
        |> ChangesetPersist.Test.with_handler(fn
          %ChangesetPersist.Delete{input: s} -> {:ok, s}
        end)
        |> Comp.run!()

      assert result == {:ok, user}
      assert [{:delete, ^user}] = calls
    end

    test "records upsert calls" do
      changeset = TestUser.changeset(%TestUser{id: 1}, %{name: "Upsert Me"})

      {result, calls} =
        comp do
          upserted <- ChangesetPersist.upsert(changeset, conflict_target: :id)
          return(upserted)
        end
        |> ChangesetPersist.Test.with_handler(fn
          %ChangesetPersist.Upsert{input: cs} -> Ecto.Changeset.apply_changes(cs)
        end)
        |> Comp.run!()

      assert result.name == "Upsert Me"
      assert [{:upsert, ^changeset}] = calls
    end

    test "records multiple operations in order" do
      changeset1 = TestUser.changeset(%TestUser{id: 1}, %{name: "First"})
      changeset2 = TestUser.changeset(%TestUser{id: 2}, %{name: "Second"})

      {_result, calls} =
        comp do
          _u1 <- ChangesetPersist.insert(changeset1)
          _u2 <- ChangesetPersist.insert(changeset2)
          return(:done)
        end
        |> ChangesetPersist.Test.with_handler(fn
          %ChangesetPersist.Insert{input: cs} -> Ecto.Changeset.apply_changes(cs)
        end)
        |> Comp.run!()

      assert [{:insert, ^changeset1}, {:insert, ^changeset2}] = calls
    end

    test "accepts handler in options" do
      changeset = TestUser.changeset(%TestUser{id: 1}, %{name: "Test"})

      {result, _calls} =
        comp do
          user <- ChangesetPersist.insert(changeset)
          return(user)
        end
        |> ChangesetPersist.Test.with_handler(
          handler: fn %ChangesetPersist.Insert{input: cs} ->
            Ecto.Changeset.apply_changes(cs)
          end
        )
        |> Comp.run!()

      assert result.name == "Test"
    end

    test "custom output function" do
      changeset = TestUser.changeset(%TestUser{id: 1}, %{name: "Test"})

      # Only return the result, discarding calls
      result =
        comp do
          user <- ChangesetPersist.insert(changeset)
          return(user)
        end
        |> ChangesetPersist.Test.with_handler(
          handler: fn %ChangesetPersist.Insert{input: cs} ->
            Ecto.Changeset.apply_changes(cs)
          end,
          output: fn result, _calls -> result end
        )
        |> Comp.run!()

      assert result.name == "Test"
    end
  end

  describe "bulk operations" do
    test "records insert_all calls" do
      changesets = [
        TestUser.changeset(%TestUser{id: 1}, %{name: "First"}),
        TestUser.changeset(%TestUser{id: 2}, %{name: "Second"})
      ]

      {result, calls} =
        comp do
          count <- ChangesetPersist.insert_all(TestUser, changesets)
          return(count)
        end
        |> ChangesetPersist.Test.with_handler(fn
          %ChangesetPersist.InsertAll{entries: entries} -> {length(entries), nil}
        end)
        |> Comp.run!()

      assert result == {2, nil}
      assert [{:insert_all, {TestUser, ^changesets, []}}] = calls
    end

    test "records update_all calls" do
      changesets = [
        TestUser.changeset(%TestUser{id: 1, name: "Old1"}, %{name: "New1"}),
        TestUser.changeset(%TestUser{id: 2, name: "Old2"}, %{name: "New2"})
      ]

      {result, calls} =
        comp do
          count <- ChangesetPersist.update_all(TestUser, changesets)
          return(count)
        end
        |> ChangesetPersist.Test.with_handler(fn
          %ChangesetPersist.UpdateAll{entries: entries} -> {length(entries), nil}
        end)
        |> Comp.run!()

      assert result == {2, nil}
      assert [{:update_all, {TestUser, ^changesets, []}}] = calls
    end

    test "records delete_all calls" do
      users = [
        %TestUser{id: 1, name: "First"},
        %TestUser{id: 2, name: "Second"}
      ]

      {result, calls} =
        comp do
          count <- ChangesetPersist.delete_all(TestUser, users)
          return(count)
        end
        |> ChangesetPersist.Test.with_handler(fn
          %ChangesetPersist.DeleteAll{entries: entries} -> {length(entries), nil}
        end)
        |> Comp.run!()

      assert result == {2, nil}
      assert [{:delete_all, {TestUser, ^users, []}}] = calls
    end
  end

  describe "default_handler/1" do
    test "handles insert" do
      changeset = TestUser.changeset(%TestUser{id: 1}, %{name: "Test"})

      {result, _calls} =
        comp do
          user <- ChangesetPersist.insert(changeset)
          return(user)
        end
        |> ChangesetPersist.Test.with_handler(&ChangesetPersist.Test.default_handler/1)
        |> Comp.run!()

      assert result.name == "Test"
    end

    test "handles update" do
      changeset = TestUser.changeset(%TestUser{id: 1, name: "Old"}, %{name: "New"})

      {result, _calls} =
        comp do
          user <- ChangesetPersist.update(changeset)
          return(user)
        end
        |> ChangesetPersist.Test.with_handler(&ChangesetPersist.Test.default_handler/1)
        |> Comp.run!()

      assert result.name == "New"
    end

    test "handles delete" do
      user = %TestUser{id: 1, name: "Test"}

      {result, _calls} =
        comp do
          deleted <- ChangesetPersist.delete(user)
          return(deleted)
        end
        |> ChangesetPersist.Test.with_handler(&ChangesetPersist.Test.default_handler/1)
        |> Comp.run!()

      assert result == {:ok, user}
    end

    test "handles insert_all" do
      changesets = [
        TestUser.changeset(%TestUser{id: 1}, %{name: "First"}),
        TestUser.changeset(%TestUser{id: 2}, %{name: "Second"})
      ]

      {result, _calls} =
        comp do
          count <- ChangesetPersist.insert_all(TestUser, changesets)
          return(count)
        end
        |> ChangesetPersist.Test.with_handler(&ChangesetPersist.Test.default_handler/1)
        |> Comp.run!()

      assert result == {2, nil}
    end

    test "handles insert_all with returning" do
      changesets = [
        TestUser.changeset(%TestUser{id: 1}, %{name: "First"}),
        TestUser.changeset(%TestUser{id: 2}, %{name: "Second"})
      ]

      {result, _calls} =
        comp do
          count <- ChangesetPersist.insert_all(TestUser, changesets, returning: true)
          return(count)
        end
        |> ChangesetPersist.Test.with_handler(&ChangesetPersist.Test.default_handler/1)
        |> Comp.run!()

      assert {2, [%TestUser{name: "First"}, %TestUser{name: "Second"}]} = result
    end
  end
end
