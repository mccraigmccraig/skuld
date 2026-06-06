defmodule Skuld.ForeignResolverTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp.ForeignSuspend
  alias Skuld.ForeignResolver
  alias Skuld.Test.Payload

  describe "ForeignResolver protocol" do
    test "resolves suspends via continuation-passing" do
      suspends = [
        %ForeignSuspend{id: :a, resume: fn v, e -> {v, e} end, payload: Payload.new(10)},
        %ForeignSuspend{id: :b, resume: fn v, e -> {v, e} end, payload: Payload.new(20)}
      ]

      first_payload = hd(suspends).payload
      result_ref = make_ref()

      result =
        ForeignResolver.await_resolutions(first_payload, suspends, fn resolved ->
          send(self(), {result_ref, resolved})
          :done
        end)

      assert result == :done
      assert_received {^result_ref, %{a: 10, b: 20}}
    end

    test "dispatches on payload type" do
      suspends = [
        %ForeignSuspend{id: :x, resume: fn v, e -> {v, e} end, payload: Payload.new(:hello)}
      ]

      ForeignResolver.await_resolutions(hd(suspends).payload, suspends, fn resolved ->
        send(self(), {:resolved, resolved})
      end)

      assert_received {:resolved, %{x: :hello}}
    end
  end
end
