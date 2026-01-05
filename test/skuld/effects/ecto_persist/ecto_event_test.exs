defmodule Skuld.Effects.EctoPersist.EctoEventTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.EctoPersist.EctoEvent
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
      event = EctoEvent.insert(cs)

      assert %EctoEvent{op: :insert, changeset: ^cs, opts: []} = event
    end

    test "insert/2 with opts" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = EctoEvent.insert(cs, returning: true)

      assert %EctoEvent{op: :insert, opts: [returning: true]} = event
    end

    test "update/2 creates an update event" do
      cs = TestUser.changeset(%TestUser{id: 1}, %{name: "Bob"})
      event = EctoEvent.update(cs)

      assert %EctoEvent{op: :update, changeset: ^cs, opts: []} = event
    end

    test "update/2 with opts" do
      cs = TestUser.changeset(%TestUser{id: 1}, %{name: "Bob"})
      event = EctoEvent.update(cs, force: true)

      assert %EctoEvent{op: :update, opts: [force: true]} = event
    end

    test "upsert/2 creates an upsert event" do
      cs = TestUser.changeset(%{name: "Charlie", email: "c@test.com"})
      event = EctoEvent.upsert(cs)

      assert %EctoEvent{op: :upsert, changeset: ^cs, opts: []} = event
    end

    test "upsert/2 with opts" do
      cs = TestUser.changeset(%{name: "Charlie", email: "c@test.com"})
      event = EctoEvent.upsert(cs, conflict_target: :email)

      assert %EctoEvent{op: :upsert, opts: [conflict_target: :email]} = event
    end

    test "delete/2 creates a delete event" do
      user = %TestUser{id: 1, name: "Dave"}
      cs = Ecto.Changeset.change(user)
      event = EctoEvent.delete(cs)

      assert %EctoEvent{op: :delete, changeset: ^cs, opts: []} = event
    end

    test "delete/2 with opts" do
      user = %TestUser{id: 1, name: "Dave"}
      cs = Ecto.Changeset.change(user)
      event = EctoEvent.delete(cs, stale_error_field: :id)

      assert %EctoEvent{op: :delete, opts: [stale_error_field: :id]} = event
    end
  end

  describe "accessors" do
    test "schema/1 extracts schema module" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = EctoEvent.insert(cs)

      assert EctoEvent.schema(event) == TestUser
    end

    test "changeset/1 extracts changeset" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = EctoEvent.insert(cs)

      assert EctoEvent.changeset(event) == cs
    end

    test "op/1 extracts operation" do
      cs = TestUser.changeset(%{name: "Alice"})

      assert EctoEvent.op(EctoEvent.insert(cs)) == :insert
      assert EctoEvent.op(EctoEvent.update(cs)) == :update
      assert EctoEvent.op(EctoEvent.upsert(cs)) == :upsert
      assert EctoEvent.op(EctoEvent.delete(cs)) == :delete
    end

    test "opts/1 extracts options" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = EctoEvent.insert(cs, returning: [:id, :name])

      assert EctoEvent.opts(event) == [returning: [:id, :name]]
    end
  end

  describe "IEvent protocol" do
    test "tag/1 returns EctoEvent module" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = EctoEvent.insert(cs)

      assert IEvent.tag(event) == EctoEvent
    end

    test "all operation types have same tag" do
      cs = TestUser.changeset(%{name: "Alice"})

      insert_event = EctoEvent.insert(cs)
      update_event = EctoEvent.update(cs)
      upsert_event = EctoEvent.upsert(cs)
      delete_event = EctoEvent.delete(cs)

      assert IEvent.tag(insert_event) == IEvent.tag(update_event)
      assert IEvent.tag(update_event) == IEvent.tag(upsert_event)
      assert IEvent.tag(upsert_event) == IEvent.tag(delete_event)
    end
  end
end
