defmodule Skuld.Effects.EventAccumulator.IEventTest do
  use ExUnit.Case, async: true

  alias Skuld.Effects.EventAccumulator.IEvent

  # Test struct for protocol tests
  defmodule TestEvent do
    defstruct [:id, :data]
  end

  defmodule AnotherEvent do
    defstruct [:value]
  end

  describe "IEvent protocol" do
    test "Any implementation returns struct module for TestEvent" do
      event = %TestEvent{id: 1, data: "test"}
      assert IEvent.tag(event) == TestEvent
    end

    test "Any implementation returns struct module for AnotherEvent" do
      event = %AnotherEvent{value: 42}
      assert IEvent.tag(event) == AnotherEvent
    end

    test "different structs have different tags" do
      event1 = %TestEvent{id: 1, data: "test"}
      event2 = %AnotherEvent{value: 42}

      refute IEvent.tag(event1) == IEvent.tag(event2)
    end

    test "same struct type has same tag" do
      event1 = %TestEvent{id: 1, data: "first"}
      event2 = %TestEvent{id: 2, data: "second"}

      assert IEvent.tag(event1) == IEvent.tag(event2)
    end
  end
end
