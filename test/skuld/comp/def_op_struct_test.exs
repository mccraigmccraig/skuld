defmodule Skuld.Comp.DefOpStructTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.SerializableStruct

  # Test effect module using def_op_struct
  defmodule TestEffect do
    import Skuld.Comp.DefOpStruct

    @sig __MODULE__
    def sig, do: @sig

    # 0-field struct
    def_op_struct Ping

    # Single-field struct
    def_op_struct Greet, [:name]

    # Multi-field struct
    def_op_struct Add, [:a, :b]

    # Struct with atom_fields option
    def_op_struct Tagged, [:tag, :value], atom_fields: [:tag]

    # Struct with multiple atom_fields
    def_op_struct MultiAtom, [:op, :target, :data], atom_fields: [:op, :target]

    # API functions using the structs
    def ping, do: Comp.effect(@sig, %Ping{})
    def greet(name), do: Comp.effect(@sig, %Greet{name: name})
    def add(a, b), do: Comp.effect(@sig, %Add{a: a, b: b})
    def tagged(tag, value), do: Comp.effect(@sig, %Tagged{tag: tag, value: value})
  end

  describe "struct generation" do
    test "0-field struct is created with empty fields" do
      ping = %TestEffect.Ping{}
      assert ping == %TestEffect.Ping{}
      assert Map.keys(ping) -- [:__struct__] == []
    end

    test "single-field struct is created with field" do
      greet = %TestEffect.Greet{name: "Alice"}
      assert greet.name == "Alice"
    end

    test "multi-field struct is created with fields" do
      add = %TestEffect.Add{a: 1, b: 2}
      assert add.a == 1
      assert add.b == 2
    end

    test "struct fields default to nil" do
      greet = %TestEffect.Greet{}
      assert greet.name == nil

      add = %TestEffect.Add{}
      assert add.a == nil
      assert add.b == nil
    end

    test "struct with atom_fields is created" do
      tagged = %TestEffect.Tagged{tag: :my_tag, value: 42}
      assert tagged.tag == :my_tag
      assert tagged.value == 42
    end
  end

  describe "handler dispatch" do
    test "0-field struct dispatches to handler" do
      result =
        TestEffect.ping()
        |> Comp.with_handler(TestEffect, fn op, env, k ->
          assert %TestEffect.Ping{} = op
          k.(:pong, env)
        end)
        |> Comp.run!()

      assert result == :pong
    end

    test "single-field struct dispatches with field values" do
      result =
        TestEffect.greet("world")
        |> Comp.with_handler(TestEffect, fn op, env, k ->
          assert %TestEffect.Greet{name: "world"} = op
          k.("hello #{op.name}", env)
        end)
        |> Comp.run!()

      assert result == "hello world"
    end

    test "multi-field struct dispatches with all fields" do
      result =
        TestEffect.add(3, 4)
        |> Comp.with_handler(TestEffect, fn op, env, k ->
          assert %TestEffect.Add{a: 3, b: 4} = op
          k.(op.a + op.b, env)
        end)
        |> Comp.run!()

      assert result == 7
    end

    test "handler can pattern match on struct" do
      handler = fn
        %TestEffect.Ping{}, env, k -> k.(:pong, env)
        %TestEffect.Greet{name: name}, env, k -> k.("hi #{name}", env)
        %TestEffect.Add{a: a, b: b}, env, k -> k.(a + b, env)
      end

      assert :pong ==
               TestEffect.ping()
               |> Comp.with_handler(TestEffect, handler)
               |> Comp.run!()

      assert "hi Bob" ==
               TestEffect.greet("Bob")
               |> Comp.with_handler(TestEffect, handler)
               |> Comp.run!()

      assert 10 ==
               TestEffect.add(6, 4)
               |> Comp.with_handler(TestEffect, handler)
               |> Comp.run!()
    end
  end

  describe "SerializableStruct.encode" do
    # Note: Jason.Encoder protocol impls defined in test modules have no effect
    # due to protocol consolidation. We test encoding via SerializableStruct.encode
    # which is what the Jason.Encoder impl delegates to.

    test "0-field struct encodes to map with __struct__ key" do
      encoded = SerializableStruct.encode(%TestEffect.Ping{})
      assert encoded["__struct__"] == "Elixir.Skuld.Comp.DefOpStructTest.TestEffect.Ping"
    end

    test "single-field struct encodes to map with fields" do
      encoded = SerializableStruct.encode(%TestEffect.Greet{name: "Alice"})
      assert encoded["__struct__"] == "Elixir.Skuld.Comp.DefOpStructTest.TestEffect.Greet"
      assert encoded[:name] == "Alice"
    end

    test "multi-field struct encodes to map with all fields" do
      encoded = SerializableStruct.encode(%TestEffect.Add{a: 1, b: 2})
      assert encoded["__struct__"] == "Elixir.Skuld.Comp.DefOpStructTest.TestEffect.Add"
      assert encoded[:a] == 1
      assert encoded[:b] == 2
    end

    test "nil fields are included in encoded map" do
      encoded = SerializableStruct.encode(%TestEffect.Greet{})
      assert Map.has_key?(encoded, :name)
      assert encoded[:name] == nil
    end

    test "encoded map is JSON-serializable" do
      encoded = SerializableStruct.encode(%TestEffect.Add{a: 1, b: 2})
      json = Jason.encode!(encoded)
      decoded = Jason.decode!(json)
      assert decoded["__struct__"] == "Elixir.Skuld.Comp.DefOpStructTest.TestEffect.Add"
      assert decoded["a"] == 1
      assert decoded["b"] == 2
    end
  end

  describe "SerializableStruct.encode/decode round-trip" do
    test "0-field struct round-trips" do
      original = %TestEffect.Ping{}
      encoded = SerializableStruct.encode(original)
      decoded = SerializableStruct.decode(encoded)
      assert decoded == original
    end

    test "single-field struct round-trips" do
      original = %TestEffect.Greet{name: "Alice"}
      encoded = SerializableStruct.encode(original)
      decoded = SerializableStruct.decode(encoded)
      assert decoded == original
    end

    test "multi-field struct round-trips" do
      original = %TestEffect.Add{a: 1, b: 2}
      encoded = SerializableStruct.encode(original)
      decoded = SerializableStruct.decode(encoded)
      assert decoded == original
    end
  end

  describe "JSON round-trip (encode -> JSON -> decode)" do
    test "0-field struct round-trips through JSON" do
      original = %TestEffect.Ping{}
      json = original |> SerializableStruct.encode() |> Jason.encode!()
      map = Jason.decode!(json)
      decoded = SerializableStruct.decode(map)
      assert decoded == original
    end

    test "single-field struct with string value round-trips through JSON" do
      original = %TestEffect.Greet{name: "Alice"}
      json = original |> SerializableStruct.encode() |> Jason.encode!()
      map = Jason.decode!(json)
      decoded = SerializableStruct.decode(map)
      assert decoded == original
    end

    test "multi-field struct with numeric values round-trips through JSON" do
      original = %TestEffect.Add{a: 1, b: 2}
      json = original |> SerializableStruct.encode() |> Jason.encode!()
      map = Jason.decode!(json)
      decoded = SerializableStruct.decode(map)
      assert decoded == original
    end
  end

  describe "atom_fields deserialization (from_json)" do
    test "from_json converts string atom_fields back to atoms" do
      # Simulate what happens after JSON decode — atom fields become strings
      map = %{"tag" => "my_tag", "value" => 42}
      result = TestEffect.Tagged.from_json(map)
      assert result == %TestEffect.Tagged{tag: :my_tag, value: 42}
    end

    test "from_json preserves atom values in atom_fields" do
      map = %{tag: :my_tag, value: 42}
      result = TestEffect.Tagged.from_json(map)
      assert result == %TestEffect.Tagged{tag: :my_tag, value: 42}
    end

    test "from_json handles nil atom_fields" do
      map = %{"tag" => nil, "value" => 42}
      result = TestEffect.Tagged.from_json(map)
      assert result == %TestEffect.Tagged{tag: nil, value: 42}
    end

    test "from_json does not convert non-atom fields" do
      map = %{"tag" => "my_tag", "value" => "a string value"}
      result = TestEffect.Tagged.from_json(map)
      assert result == %TestEffect.Tagged{tag: :my_tag, value: "a string value"}
    end

    test "from_json handles multiple atom_fields" do
      map = %{"op" => "insert", "target" => "users", "data" => %{name: "Alice"}}
      result = TestEffect.MultiAtom.from_json(map)
      assert result == %TestEffect.MultiAtom{op: :insert, target: :users, data: %{name: "Alice"}}
    end

    test "struct with atom_fields round-trips through JSON" do
      original = %TestEffect.Tagged{tag: :my_tag, value: 42}
      json = original |> SerializableStruct.encode() |> Jason.encode!()
      map = Jason.decode!(json)

      # SerializableStruct.decode delegates to from_json when available
      decoded = SerializableStruct.decode(map)
      assert decoded == original
    end

    test "struct with multiple atom_fields round-trips through JSON" do
      original = %TestEffect.MultiAtom{op: :insert, target: :users, data: "payload"}
      json = original |> SerializableStruct.encode() |> Jason.encode!()
      map = Jason.decode!(json)
      decoded = SerializableStruct.decode(map)
      assert decoded == original
    end
  end

  describe "from_json is only generated when atom_fields present" do
    test "struct without atom_fields does not have from_json" do
      refute function_exported?(TestEffect.Ping, :from_json, 1)
      refute function_exported?(TestEffect.Greet, :from_json, 1)
      refute function_exported?(TestEffect.Add, :from_json, 1)
    end

    test "struct with atom_fields has from_json" do
      assert function_exported?(TestEffect.Tagged, :from_json, 1)
      assert function_exported?(TestEffect.MultiAtom, :from_json, 1)
    end
  end
end
