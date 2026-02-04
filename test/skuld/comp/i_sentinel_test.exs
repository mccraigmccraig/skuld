defmodule Skuld.Comp.ISentinelTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp.Cancelled
  alias Skuld.Comp.ExternalSuspend
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Comp.ISentinel
  alias Skuld.Comp.Throw

  describe "ISentinel predicates" do
    test "plain values are not sentinels" do
      for value <- [:atom, "string", 42, %{map: true}, [1, 2, 3], {:tuple, :value}] do
        assert ISentinel.sentinel?(value) == false
        assert ISentinel.suspend?(value) == false
        assert ISentinel.error?(value) == false
      end
    end

    test "ExternalSuspend is a suspend sentinel" do
      suspend = %ExternalSuspend{value: :test, resume: fn _ -> {:ok, nil} end}
      assert ISentinel.sentinel?(suspend) == true
      assert ISentinel.suspend?(suspend) == true
      assert ISentinel.error?(suspend) == false
    end

    test "InternalSuspend is a suspend sentinel" do
      suspend = InternalSuspend.batch(%{op: :test}, make_ref(), fn val, env -> {val, env} end)
      assert ISentinel.sentinel?(suspend) == true
      assert ISentinel.suspend?(suspend) == true
      assert ISentinel.error?(suspend) == false
    end

    test "Throw is an error sentinel" do
      throw = %Throw{error: :some_error}
      assert ISentinel.sentinel?(throw) == true
      assert ISentinel.suspend?(throw) == false
      assert ISentinel.error?(throw) == true
    end

    test "Cancelled is an error sentinel" do
      cancelled = %Cancelled{reason: :timeout}
      assert ISentinel.sentinel?(cancelled) == true
      assert ISentinel.suspend?(cancelled) == false
      assert ISentinel.error?(cancelled) == true
    end
  end

  describe "sentinel category coverage" do
    test "all sentinels are either suspend or error" do
      sentinels = [
        %ExternalSuspend{value: :test},
        InternalSuspend.batch(%{op: :test}, make_ref(), fn val, env -> {val, env} end),
        %Throw{error: :test},
        %Cancelled{reason: :test}
      ]

      for sentinel <- sentinels do
        assert ISentinel.sentinel?(sentinel) == true
        # Every sentinel is either suspend or error (or both, but currently none are both)
        is_categorized = ISentinel.suspend?(sentinel) or ISentinel.error?(sentinel)
        assert is_categorized, "Sentinel #{inspect(sentinel)} should be suspend or error"
      end
    end

    test "suspend and error are mutually exclusive" do
      sentinels = [
        %ExternalSuspend{value: :test},
        InternalSuspend.batch(%{op: :test}, make_ref(), fn val, env -> {val, env} end),
        %Throw{error: :test},
        %Cancelled{reason: :test}
      ]

      for sentinel <- sentinels do
        is_suspend = ISentinel.suspend?(sentinel)
        is_error = ISentinel.error?(sentinel)
        # Currently, no sentinel is both suspend and error
        refute is_suspend and is_error,
               "Sentinel #{inspect(sentinel)} should not be both suspend and error"
      end
    end
  end
end
