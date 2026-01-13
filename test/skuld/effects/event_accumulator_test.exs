defmodule Skuld.Effects.EventAccumulatorTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.ChangeEvent
  alias Skuld.Effects.EventAccumulator
  alias Skuld.Effects.EventAccumulator.IEvent

  # Test schema for EctoEvent tests
  defmodule TestUser do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  # Custom event struct for tests
  defmodule CustomEvent do
    defstruct [:data]
  end

  describe "emit/1" do
    test "emits ChangeEvent and returns :ok" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = ChangeEvent.insert(cs)

      computation =
        comp do
          result <- EventAccumulator.emit(event)
          return(result)
        end
        |> EventAccumulator.with_handler()

      assert Comp.run!(computation) == :ok
    end

    test "emits custom event" do
      event = %CustomEvent{data: "test"}

      computation =
        comp do
          _ <- EventAccumulator.emit(event)
          return(:done)
        end
        |> EventAccumulator.with_handler()

      assert Comp.run!(computation) == :done
    end
  end

  describe "with_handler/2" do
    test "default output returns just result" do
      cs = TestUser.changeset(%{name: "Alice"})

      computation =
        comp do
          _ <- EventAccumulator.emit(ChangeEvent.insert(cs))
          return(42)
        end
        |> EventAccumulator.with_handler()

      assert Comp.run!(computation) == 42
    end

    test "output: &{&1, &2} returns {result, events}" do
      cs = TestUser.changeset(%{name: "Alice"})
      event = ChangeEvent.insert(cs)

      computation =
        comp do
          _ <- EventAccumulator.emit(event)
          return(:ok)
        end
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {result, events} = Comp.run!(computation)

      assert result == :ok
      assert length(events) == 1
      assert hd(events) == event
    end

    test "custom output function" do
      cs = TestUser.changeset(%{name: "Alice"})

      computation =
        comp do
          _ <- EventAccumulator.emit(ChangeEvent.insert(cs))
          return(:ignored)
        end
        |> EventAccumulator.with_handler(output: fn _result, events -> events end)

      events = Comp.run!(computation)

      assert length(events) == 1
    end
  end

  describe "event ordering" do
    test "events are accumulated in emission order" do
      user_cs = TestUser.changeset(%{name: "Alice"})
      custom_event = %CustomEvent{data: "test"}

      computation =
        comp do
          _ <- EventAccumulator.emit(ChangeEvent.insert(user_cs))
          _ <- EventAccumulator.emit(custom_event)
          _ <- EventAccumulator.emit(ChangeEvent.update(user_cs))
          return(:ok)
        end
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {:ok, events} = Comp.run!(computation)

      # Events in emission order - mixed types preserved
      assert length(events) == 3
      [first, second, third] = events

      assert %ChangeEvent{op: :insert} = first
      assert %CustomEvent{data: "test"} = second
      assert %ChangeEvent{op: :update} = third
    end

    test "multiple events accumulate in order" do
      computation =
        comp do
          _ <- EventAccumulator.emit(%CustomEvent{data: "first"})
          _ <- EventAccumulator.emit(%CustomEvent{data: "second"})
          _ <- EventAccumulator.emit(%CustomEvent{data: "third"})
          return(:ok)
        end
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {:ok, events} = Comp.run!(computation)

      assert length(events) == 3

      # Events in emission order
      [first, second, third] = events
      assert first.data == "first"
      assert second.data == "second"
      assert third.data == "third"
    end

    test "empty computation produces empty list" do
      computation =
        comp do
          return(:ok)
        end
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {:ok, events} = Comp.run!(computation)

      assert events == []
    end
  end

  describe "IEvent protocol for consumer grouping" do
    test "IEvent.tag/1 returns module name for structs" do
      assert IEvent.tag(%CustomEvent{data: "test"}) == CustomEvent
      assert IEvent.tag(%ChangeEvent{op: :insert, changeset: nil, opts: []}) == ChangeEvent
    end

    test "consumers can group events by tag" do
      user_cs = TestUser.changeset(%{name: "Alice"})
      custom_event = %CustomEvent{data: "test"}

      computation =
        comp do
          _ <- EventAccumulator.emit(ChangeEvent.insert(user_cs))
          _ <- EventAccumulator.emit(custom_event)
          _ <- EventAccumulator.emit(ChangeEvent.update(user_cs))
          return(:ok)
        end
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {:ok, events} = Comp.run!(computation)

      # Consumer groups events using IEvent.tag
      events_by_tag = Enum.group_by(events, &IEvent.tag/1)

      assert Map.has_key?(events_by_tag, ChangeEvent)
      assert Map.has_key?(events_by_tag, CustomEvent)
      assert length(events_by_tag[ChangeEvent]) == 2
      assert length(events_by_tag[CustomEvent]) == 1
    end
  end

  describe "integration with ChangeEvent" do
    test "accumulates multiple ChangeEvents with different operations" do
      cs1 = TestUser.changeset(%{name: "Alice"})
      cs2 = TestUser.changeset(%TestUser{id: 1}, %{name: "Bob"})
      cs3 = Ecto.Changeset.change(%TestUser{id: 2})

      computation =
        comp do
          _ <- EventAccumulator.emit(ChangeEvent.insert(cs1))
          _ <- EventAccumulator.emit(ChangeEvent.update(cs2))
          _ <- EventAccumulator.emit(ChangeEvent.delete(cs3))
          return(:ok)
        end
        |> EventAccumulator.with_handler(output: &{&1, &2})

      {:ok, events} = Comp.run!(computation)

      assert length(events) == 3

      [insert, update, delete] = events
      assert ChangeEvent.op(insert) == :insert
      assert ChangeEvent.op(update) == :update
      assert ChangeEvent.op(delete) == :delete
    end
  end
end
