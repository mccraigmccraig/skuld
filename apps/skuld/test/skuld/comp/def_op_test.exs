defmodule Skuld.Comp.DefOpTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp

  # Test effect module using def_op
  defmodule SimpleEffect do
    use Skuld.Comp.DefOp

    def_op(ping())
    def_op(add(a, b))
    def_op(greet(name))
  end

  describe "def_op with 0 args" do
    test "generates a function that returns a computation" do
      comp = SimpleEffect.ping()
      assert is_function(comp, 2)
    end

    test "computation dispatches to handler with bare atom op" do
      comp = SimpleEffect.ping()

      result =
        comp
        |> Comp.with_handler(SimpleEffect, fn op, env, k ->
          # 0-arg op should be a bare atom
          assert op == SimpleEffect.Ping
          k.(:pong, env)
        end)
        |> Comp.run!()

      assert result == :pong
    end
  end

  describe "def_op with args" do
    test "generates a function that accepts args and returns a computation" do
      comp = SimpleEffect.add(1, 2)
      assert is_function(comp, 2)
    end

    test "computation dispatches to handler with tagged tuple op" do
      comp = SimpleEffect.add(3, 4)

      result =
        comp
        |> Comp.with_handler(SimpleEffect, fn op, env, k ->
          # N-arg op should be a tagged tuple
          assert op == {SimpleEffect.Add, 3, 4}
          {_op_tag, a, b} = op
          k.(a + b, env)
        end)
        |> Comp.run!()

      assert result == 7
    end

    test "single-arg op produces a 2-tuple" do
      comp = SimpleEffect.greet("world")

      result =
        comp
        |> Comp.with_handler(SimpleEffect, fn op, env, k ->
          assert op == {SimpleEffect.Greet, "world"}
          {_op_tag, name} = op
          k.("hello #{name}", env)
        end)
        |> Comp.run!()

      assert result == "hello world"
    end
  end

  describe "op atom naming" do
    test "snake_case function name becomes CamelCase op atom" do
      # ping -> Ping, add -> Add, greet -> Greet
      # These are nested under the effect module
      assert SimpleEffect.Ping == Module.concat(SimpleEffect, :Ping)
      assert SimpleEffect.Add == Module.concat(SimpleEffect, :Add)
      assert SimpleEffect.Greet == Module.concat(SimpleEffect, :Greet)
    end
  end

  describe "sig/0" do
    test "returns __MODULE__ of the defining module" do
      assert SimpleEffect.sig() == SimpleEffect
    end
  end

  describe "sig/1" do
    test "sig(__MODULE__) returns __MODULE__ directly" do
      assert SimpleEffect.sig(SimpleEffect) == SimpleEffect
    end

    test "sig(tag) returns camelized Module.concat(__MODULE__, tag)" do
      assert SimpleEffect.sig(:counter) == Module.concat(SimpleEffect, :Counter)
      assert SimpleEffect.sig(:my_tag) == Module.concat(SimpleEffect, :MyTag)
    end
  end

  describe "handler dispatch" do
    test "sig is always __MODULE__ of the defining module" do
      # Verify by checking the handler key used
      comp = SimpleEffect.ping()

      # Install handler under SimpleEffect - should be found
      result =
        comp
        |> Comp.with_handler(SimpleEffect, fn _op, env, k -> k.(:ok, env) end)
        |> Comp.run!()

      assert result == :ok
    end
  end
end
