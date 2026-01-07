defmodule Skuld.Effects.FreshTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Fresh

  describe "fresh/0" do
    test "generates sequential integers starting from 0" do
      result =
        comp do
          a <- Fresh.fresh()
          b <- Fresh.fresh()
          c <- Fresh.fresh()
          return({a, b, c})
        end
        |> Fresh.with_handler()
        |> Comp.run!()

      assert result == {0, 1, 2}
    end

    test "starts from custom seed value" do
      result =
        comp do
          a <- Fresh.fresh()
          b <- Fresh.fresh()
          return({a, b})
        end
        |> Fresh.with_handler(seed: 100)
        |> Comp.run!()

      assert result == {100, 101}
    end

    test "nested handlers are independent" do
      result =
        comp do
          outer1 <- Fresh.fresh()

          inner_result <-
            comp do
              inner1 <- Fresh.fresh()
              inner2 <- Fresh.fresh()
              return({inner1, inner2})
            end
            |> Fresh.with_handler(seed: 1000)

          outer2 <- Fresh.fresh()
          return({outer1, inner_result, outer2})
        end
        |> Fresh.with_handler()
        |> Comp.run!()

      assert result == {0, {1000, 1001}, 1}
    end

    test "output option transforms result with final counter" do
      result =
        comp do
          _ <- Fresh.fresh()
          _ <- Fresh.fresh()
          _ <- Fresh.fresh()
          return(:done)
        end
        |> Fresh.with_handler(output: fn result, counter -> {result, counter} end)
        |> Comp.run!()

      assert result == {:done, 3}
    end
  end

  describe "fresh_uuid/0" do
    test "generates valid UUIDs" do
      result =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_handler()
        |> Comp.run!()

      # UUID format: 8-4-4-4-12 hex characters
      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               result
             )
    end

    test "generates unique UUIDs" do
      result =
        comp do
          uuid1 <- Fresh.fresh_uuid()
          uuid2 <- Fresh.fresh_uuid()
          uuid3 <- Fresh.fresh_uuid()
          return({uuid1, uuid2, uuid3})
        end
        |> Fresh.with_handler()
        |> Comp.run!()

      {uuid1, uuid2, uuid3} = result
      assert uuid1 != uuid2
      assert uuid2 != uuid3
      assert uuid1 != uuid3
    end

    test "same namespace produces same UUID sequence" do
      namespace = Uniq.UUID.uuid4()

      uuids1 =
        comp do
          a <- Fresh.fresh_uuid()
          b <- Fresh.fresh_uuid()
          return({a, b})
        end
        |> Fresh.with_handler(namespace: namespace)
        |> Comp.run!()

      uuids2 =
        comp do
          a <- Fresh.fresh_uuid()
          b <- Fresh.fresh_uuid()
          return({a, b})
        end
        |> Fresh.with_handler(namespace: namespace)
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
        |> Fresh.with_handler(namespace: namespace1)
        |> Comp.run!()

      uuid2 =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_handler(namespace: namespace2)
        |> Comp.run!()

      assert uuid1 != uuid2
    end

    test "supports standard UUID namespaces" do
      result =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_handler(namespace: :dns)
        |> Comp.run!()

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               result
             )
    end
  end

  describe "mixed fresh/0 and fresh_uuid/0" do
    test "share the same counter" do
      result =
        comp do
          int1 <- Fresh.fresh()
          _uuid1 <- Fresh.fresh_uuid()
          int2 <- Fresh.fresh()
          _uuid2 <- Fresh.fresh_uuid()
          return({int1, int2})
        end
        |> Fresh.with_handler(output: fn {int1, int2}, counter -> {{int1, int2}, counter} end)
        |> Comp.run!()

      # int1=0, uuid1 uses 1, int2=2, uuid2 uses 3 -> final counter is 4
      assert result == {{0, 2}, 4}
    end

    test "uuid generation is deterministic based on counter position" do
      namespace = Uniq.UUID.uuid4()

      # Generate UUID at position 0
      uuid_at_0 =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_handler(namespace: namespace)
        |> Comp.run!()

      # Generate UUID at position 0 again (after skipping with fresh)
      uuid_at_0_v2 =
        comp do
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_handler(namespace: namespace)
        |> Comp.run!()

      # Generate UUID at position 1
      uuid_at_1 =
        comp do
          _ <- Fresh.fresh()
          uuid <- Fresh.fresh_uuid()
          return(uuid)
        end
        |> Fresh.with_handler(namespace: namespace)
        |> Comp.run!()

      assert uuid_at_0 == uuid_at_0_v2
      assert uuid_at_0 != uuid_at_1
    end
  end

  describe "get_counter/1" do
    test "returns current counter from env" do
      {_result, env} =
        comp do
          _ <- Fresh.fresh()
          _ <- Fresh.fresh()
          return(:ok)
        end
        |> Fresh.with_handler()
        |> Comp.run()

      # After handler completes, the state is cleaned up
      # So get_counter returns 0 (default)
      assert Fresh.get_counter(env) == 0
    end
  end
end
