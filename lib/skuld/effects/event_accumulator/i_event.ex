defprotocol Skuld.Effects.EventAccumulator.IEvent do
  @moduledoc """
  Protocol for tagging events for grouping.

  This protocol is provided for consumers of the event log who want to
  group events by type. The accumulator itself does not use this protocol -
  it simply accumulates all events in a list.

  ## Example

      alias Skuld.Effects.EventAccumulator.IEvent

      # Get events grouped by tag
      {result, events} = comp |> EventAccumulator.with_handler(output: &{&1, &2}) |> Comp.run!()
      events_by_tag = Enum.group_by(events, &IEvent.tag/1)

  ## Default Behavior

  By default (via the `Any` implementation), structs are tagged
  by their module name:

      IEvent.tag(%MyApp.UserCreated{user_id: 1})
      #=> MyApp.UserCreated

  ## Custom Implementation

  You can implement the protocol for custom grouping:

      defimpl Skuld.Effects.EventAccumulator.IEvent, for: MyApp.DomainEvent do
        def tag(%{aggregate_type: type}), do: type
      end
  """

  @fallback_to_any true

  @doc """
  Returns the tag for grouping this event.

  The tag is typically an atom (module name) used to group
  related events together.
  """
  @spec tag(t) :: atom()
  def tag(event)
end

defimpl Skuld.Effects.EventAccumulator.IEvent, for: Any do
  @moduledoc """
  Default implementation for any struct.

  Returns the struct's module name as the tag.
  """

  def tag(%{__struct__: module}), do: module
end
