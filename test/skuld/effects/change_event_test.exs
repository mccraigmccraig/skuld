defmodule Skuld.Effects.ChangeEventTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.ChangeEvent
  alias Skuld.Effects.EventAccumulator.IEvent

  # Simple test schema
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

  describe "constructors" do
    test "insert/2 creates an insert event" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = ChangeEvent.insert(cs)

      assert %ChangeEvent{op: :insert, changeset: ^cs, opts: []} = event
    end

    test "insert/2 with opts" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = ChangeEvent.insert(cs, returning: true)

      assert %ChangeEvent{op: :insert, opts: [returning: true]} = event
    end

    test "update/2 creates an update event" do
      cs = TestUser.changeset(%TestUser{id: 1}, %{name: "Bob"})
      event = ChangeEvent.update(cs)

      assert %ChangeEvent{op: :update, changeset: ^cs, opts: []} = event
    end

    test "update/2 with opts" do
      cs = TestUser.changeset(%TestUser{id: 1}, %{name: "Bob"})
      event = ChangeEvent.update(cs, force: true)

      assert %ChangeEvent{op: :update, opts: [force: true]} = event
    end

    test "upsert/2 creates an upsert event" do
      cs = TestUser.changeset(%{name: "Charlie", email: "c@test.com"})
      event = ChangeEvent.upsert(cs)

      assert %ChangeEvent{op: :upsert, changeset: ^cs, opts: []} = event
    end

    test "upsert/2 with opts" do
      cs = TestUser.changeset(%{name: "Charlie", email: "c@test.com"})
      event = ChangeEvent.upsert(cs, conflict_target: :email)

      assert %ChangeEvent{op: :upsert, opts: [conflict_target: :email]} = event
    end

    test "delete/2 creates a delete event" do
      user = %TestUser{id: 1, name: "Dave"}
      cs = Ecto.Changeset.change(user)
      event = ChangeEvent.delete(cs)

      assert %ChangeEvent{op: :delete, changeset: ^cs, opts: []} = event
    end

    test "delete/2 with opts" do
      user = %TestUser{id: 1, name: "Dave"}
      cs = Ecto.Changeset.change(user)
      event = ChangeEvent.delete(cs, stale_error_field: :id)

      assert %ChangeEvent{op: :delete, opts: [stale_error_field: :id]} = event
    end
  end

  describe "accessors" do
    test "schema/1 extracts schema module" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = ChangeEvent.insert(cs)

      assert ChangeEvent.schema(event) == TestUser
    end

    test "changeset/1 extracts changeset" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = ChangeEvent.insert(cs)

      assert ChangeEvent.changeset(event) == cs
    end

    test "op/1 extracts operation" do
      cs = TestUser.changeset(%{name: "Alice"})

      assert ChangeEvent.op(ChangeEvent.insert(cs)) == :insert
      assert ChangeEvent.op(ChangeEvent.update(cs)) == :update
      assert ChangeEvent.op(ChangeEvent.upsert(cs)) == :upsert
      assert ChangeEvent.op(ChangeEvent.delete(cs)) == :delete
    end

    test "opts/1 extracts options" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = ChangeEvent.insert(cs, returning: [:id, :name])

      assert ChangeEvent.opts(event) == [returning: [:id, :name]]
    end
  end

  describe "IEvent protocol" do
    test "tag/1 returns ChangeEvent module" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = ChangeEvent.insert(cs)

      assert IEvent.tag(event) == ChangeEvent
    end

    test "all operation types have same tag" do
      cs = TestUser.changeset(%{name: "Alice"})

      insert_event = ChangeEvent.insert(cs)
      update_event = ChangeEvent.update(cs)
      upsert_event = ChangeEvent.upsert(cs)
      delete_event = ChangeEvent.delete(cs)

      assert IEvent.tag(insert_event) == IEvent.tag(update_event)
      assert IEvent.tag(update_event) == IEvent.tag(upsert_event)
      assert IEvent.tag(upsert_event) == IEvent.tag(delete_event)
    end
  end
end
