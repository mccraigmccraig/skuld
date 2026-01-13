defmodule Skuld.Effects.EventAccumulator do
  @moduledoc """
  Effect for accumulating events during computation.

  Accumulates events in a simple list, preserving emission order.
  This follows the
  [Decider pattern](https://thinkbeforecoding.com/post/2021/12/17/functional-event-sourcing-decider#Stitching-it-together)
  where Events are facts about what happened.

  ## Example

      alias Skuld.Effects.{EventAccumulator, ChangeEvent}
      alias Skuld.Comp

      use Skuld.Syntax

      # Accumulate events during computation
      comp do
        user_cs = User.changeset(%User{}, %{name: "Alice"})
        _ <- EventAccumulator.emit(ChangeEvent.insert(user_cs))

        order_cs = Order.changeset(%Order{}, %{user_id: 1})
        _ <- EventAccumulator.emit(ChangeEvent.insert(order_cs))

        return(:ok)
      end
      |> EventAccumulator.with_handler(output: &{&1, &2})
      |> Comp.run!()
      #=> {:ok, [%ChangeEvent{...}, %ChangeEvent{...}]}

  ## Options

  The `with_handler/2` accepts:

    * `:output` - Transform function `(result, events) -> output`.
      Default returns just the result, discarding the events.
      Use `output: &{&1, &2}` to get `{result, events}`.

  ## Grouping Events

  If you need to group events by type, use `EventAccumulator.IEvent.tag/1`:

      {result, events} = ...
      events_by_tag = Enum.group_by(events, &EventAccumulator.IEvent.tag/1)

  ## See Also

    * `Skuld.Effects.Writer` - The underlying effect
    * `Skuld.Effects.ChangeEvent` - Generic changeset operation wrapper
  """

  alias Skuld.Effects.Writer
  alias Skuld.Comp
  alias Skuld.Comp.Types

  @doc """
  Emit an event.

  The event will be accumulated in emission order.

  Returns `:ok`.

  ## Example

      _ <- EventAccumulator.emit(ChangeEvent.insert(changeset))
      _ <- EventAccumulator.emit(%MyCustomEvent{data: "hello"})
  """
  @spec emit(term()) :: Types.computation()
  def emit(event) do
    Writer.tell(__MODULE__, event)
    |> Comp.then_do(Comp.pure(:ok))
  end

  @doc """
  Install handler to capture events.

  ## Options

    * `:output` - Transform function `(result, events) -> output`.
      Default returns just the result, discarding the events.
      Use `output: &{&1, &2}` to get `{result, events}`.

  ## Example

      comp
      |> EventAccumulator.with_handler()
      |> Comp.run!()
      #=> result (events discarded)

      comp
      |> EventAccumulator.with_handler(output: &{&1, &2})
      |> Comp.run!()
      #=> {result, [event1, event2, ...]}

      comp
      |> EventAccumulator.with_handler(output: fn _result, events -> events end)
      |> Comp.run!()
      #=> [event1, event2, ...]
  """
  @spec with_handler(Types.computation(), keyword()) :: Types.computation()
  def with_handler(comp, opts \\ []) do
    user_output = Keyword.get(opts, :output)

    # Transform to reverse the log (Writer stores in reverse order)
    internal_output = fn result, raw_log ->
      events = Enum.reverse(raw_log)

      if user_output do
        user_output.(result, events)
      else
        result
      end
    end

    Writer.with_handler(comp, [], tag: __MODULE__, output: internal_output)
  end
end
