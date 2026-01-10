defmodule Skuld.Effects.FreshTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Fresh

  describe "with_uuid7_handler (production)" do
    test "generates valid v7 UUIDs" do
      result =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_uuid7_handler()
        |> Comp.run!()

      # UUID format: 8-4-4-4-12 hex characters
      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               result
             )

      # v7 UUIDs have version 7 in the 13th character
      assert String.at(result, 14) == "7"
    end

    test "generates unique UUIDs" do
      result =
        comp do
          uuid1 <- Fresh.fresh_uuid()
          uuid2 <- Fresh.fresh_uuid()
          uuid3 <- Fresh.fresh_uuid()
          return({uuid1, uuid2, uuid3})
        end
        |> Fresh.with_uuid7_handler()
        |> Comp.run!()

      {uuid1, uuid2, uuid3} = result
      assert uuid1 != uuid2
      assert uuid2 != uuid3
      assert uuid1 != uuid3
    end

    test "UUIDs generated with time gap are time-ordered" do
      # v7 UUIDs have millisecond precision, so we need a gap
      uuid1 =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_uuid7_handler()
        |> Comp.run!()

      Process.sleep(2)

      uuid2 =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_uuid7_handler()
        |> Comp.run!()

      # v7 UUIDs generated with time gap should be lexically ordered
      assert uuid1 < uuid2
    end

    test "output option transforms result with count" do
      result =
        comp do
          _ <- Fresh.fresh_uuid()
          _ <- Fresh.fresh_uuid()
          _ <- Fresh.fresh_uuid()
          return(:done)
        end
        |> Fresh.with_uuid7_handler(output: fn result, count -> {result, count} end)
        |> Comp.run!()

      assert result == {:done, 3}
    end

    test "nested handlers are independent" do
      result =
        comp do
          outer1 <- Fresh.fresh_uuid()

          inner_result <-
            comp do
              inner1 <- Fresh.fresh_uuid()
              inner2 <- Fresh.fresh_uuid()
              return({inner1, inner2})
            end
            |> Fresh.with_uuid7_handler()

          outer2 <- Fresh.fresh_uuid()
          return({outer1, inner_result, outer2})
        end
        |> Fresh.with_uuid7_handler(output: fn r, count -> {r, count} end)
        |> Comp.run!()

      {{outer1, {inner1, inner2}, outer2}, outer_count} = result

      # All UUIDs should be unique
      all_uuids = [outer1, inner1, inner2, outer2]
      assert length(Enum.uniq(all_uuids)) == 4

      # Outer handler should have count 2 (outer1, outer2)
      assert outer_count == 2
    end
  end

  describe "with_test_handler (deterministic)" do
    test "generates valid UUIDs" do
      result =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_test_handler()
        |> Comp.run!()

      # UUID format: 8-4-4-4-12 hex characters
      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               result
             )

      # v5 UUIDs have version 5 in the 13th character
      assert String.at(result, 14) == "5"
    end

    test "generates unique UUIDs within same run" do
      result =
        comp do
          uuid1 <- Fresh.fresh_uuid()
          uuid2 <- Fresh.fresh_uuid()
          uuid3 <- Fresh.fresh_uuid()
          return({uuid1, uuid2, uuid3})
        end
        |> Fresh.with_test_handler()
        |> Comp.run!()

      {uuid1, uuid2, uuid3} = result
      assert uuid1 != uuid2
      assert uuid2 != uuid3
      assert uuid1 != uuid3
    end

    test "same namespace produces same UUID sequence (deterministic)" do
      namespace = Uniq.UUID.uuid4()

      uuids1 =
        comp do
          a <- Fresh.fresh_uuid()
          b <- Fresh.fresh_uuid()
          return({a, b})
        end
        |> Fresh.with_test_handler(namespace: namespace)
        |> Comp.run!()

      uuids2 =
        comp do
          a <- Fresh.fresh_uuid()
          b <- Fresh.fresh_uuid()
          return({a, b})
        end
        |> Fresh.with_test_handler(namespace: namespace)
        |> Comp.run!()

      assert uuids1 == uuids2
    end

    test "different namespaces produce different UUID sequences" do
      namespace1 = Uniq.UUID.uuid4()
      namespace2 = Uniq.UUID.uuid4()

      uuid1 =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_test_handler(namespace: namespace1)
        |> Comp.run!()

      uuid2 =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_test_handler(namespace: namespace2)
        |> Comp.run!()

      assert uuid1 != uuid2
    end

    test "seed option affects counter start position" do
      namespace = Uniq.UUID.uuid4()

      # UUID at counter position 0
      uuid_at_0 =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_test_handler(namespace: namespace, seed: 0)
        |> Comp.run!()

      # UUID at counter position 100
      uuid_at_100 =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_test_handler(namespace: namespace, seed: 100)
        |> Comp.run!()

      assert uuid_at_0 != uuid_at_100

      # Verify position 100 is deterministic
      uuid_at_100_again =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_test_handler(namespace: namespace, seed: 100)
        |> Comp.run!()

      assert uuid_at_100 == uuid_at_100_again
    end

    test "supports standard UUID namespaces" do
      result =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_test_handler(namespace: :dns)
        |> Comp.run!()

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               result
             )
    end

    test "output option transforms result with final counter" do
      result =
        comp do
          _ <- Fresh.fresh_uuid()
          _ <- Fresh.fresh_uuid()
          _ <- Fresh.fresh_uuid()
          return(:done)
        end
        |> Fresh.with_test_handler(output: fn result, counter -> {result, counter} end)
        |> Comp.run!()

      assert result == {:done, 3}
    end

    test "nested handlers are independent" do
      namespace = Uniq.UUID.uuid4()

      result =
        comp do
          outer1 <- Fresh.fresh_uuid()

          inner_result <-
            comp do
              inner1 <- Fresh.fresh_uuid()
              inner2 <- Fresh.fresh_uuid()
              return({inner1, inner2})
            end
            |> Fresh.with_test_handler(namespace: namespace, seed: 1000)

          outer2 <- Fresh.fresh_uuid()
          return({outer1, inner_result, outer2})
        end
        |> Fresh.with_test_handler(namespace: namespace)
        |> Comp.run!()

      {outer1, {inner1, inner2}, outer2} = result

      # Outer: positions 0 and 1, Inner: positions 1000 and 1001
      # All should be different (different counter positions)
      all_uuids = [outer1, inner1, inner2, outer2]
      assert length(Enum.uniq(all_uuids)) == 4
    end
  end

  describe "get_counter/1" do
    test "returns 0 when no handler state present" do
      {_result, env} =
        Comp.pure(:ok)
        |> Comp.run()

      assert Fresh.get_counter(env) == 0
    end
  end
end
