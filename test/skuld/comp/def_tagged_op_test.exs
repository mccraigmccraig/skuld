defmodule Skuld.Comp.DefTaggedOpTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp

  # Test effect module using def_tagged_op
  defmodule TaggedEffect do
    use Skuld.Comp.DefTaggedOp

    def_tagged_op get()
    def_tagged_op put(value)
    def_tagged_op modify(fun)
  end

  describe "def_tagged_op with default tag" do
    test "generates function with optional tag defaulting to __MODULE__" do
      # Can call with no tag (uses default)
      comp = TaggedEffect.get()
      assert is_function(comp, 2)
    end

    test "0-arg op with default tag dispatches with bare atom and __MODULE__ sig" do
      comp = TaggedEffect.get()

      result =
        comp
        |> Comp.with_handler(TaggedEffect, fn op, env, k ->
          # 0-arg op (after tag) should be a bare atom
          assert op == TaggedEffect.Get
          k.(:the_value, env)
        end)
        |> Comp.run!()

      assert result == :the_value
    end

    test "1-arg op with default tag dispatches with tagged tuple" do
      comp = TaggedEffect.put(42)

      result =
        comp
        |> Comp.with_handler(TaggedEffect, fn op, env, k ->
          assert op == {TaggedEffect.Put, 42}
          k.(:ok, env)
        end)
        |> Comp.run!()

      assert result == :ok
    end
  end

  describe "def_tagged_op with explicit tag" do
    test "explicit tag uses camelized Module.concat sig" do
      comp = TaggedEffect.get(:counter)

      expected_sig = TaggedEffect.sig(:counter)

      result =
        comp
        |> Comp.with_handler(expected_sig, fn op, env, k ->
          assert op == TaggedEffect.Get
          k.(:counter_value, env)
        end)
        |> Comp.run!()

      assert result == :counter_value
    end

    test "different tags dispatch to different handlers" do
      use Skuld.Syntax

      computation =
        comp do
          a <- TaggedEffect.get(:alpha)
          b <- TaggedEffect.get(:beta)
          return({a, b})
        end

      alpha_sig = TaggedEffect.sig(:alpha)
      beta_sig = TaggedEffect.sig(:beta)

      result =
        computation
        |> Comp.with_handler(alpha_sig, fn _op, env, k -> k.(:from_alpha, env) end)
        |> Comp.with_handler(beta_sig, fn _op, env, k -> k.(:from_beta, env) end)
        |> Comp.run!()

      assert result == {:from_alpha, :from_beta}
    end

    test "multi-arg op with explicit tag" do
      comp = TaggedEffect.put(:cache, %{key: "value"})

      expected_sig = TaggedEffect.sig(:cache)

      result =
        comp
        |> Comp.with_handler(expected_sig, fn op, env, k ->
          assert op == {TaggedEffect.Put, %{key: "value"}}
          k.(:stored, env)
        end)
        |> Comp.run!()

      assert result == :stored
    end
  end

  describe "sig/0" do
    test "returns __MODULE__ of the defining module" do
      assert TaggedEffect.sig() == TaggedEffect
    end
  end

  describe "sig/1 helper" do
    test "sig(__MODULE__) returns __MODULE__ directly" do
      assert TaggedEffect.sig(TaggedEffect) == TaggedEffect
    end

    test "sig(tag) returns camelized Module.concat(__MODULE__, tag)" do
      assert TaggedEffect.sig(:counter) == Module.concat(TaggedEffect, :Counter)
      assert TaggedEffect.sig(:my_tag) == Module.concat(TaggedEffect, :MyTag)
    end

    test "sig(list) concatenates multiple camelized segments" do
      assert TaggedEffect.sig([:agent, :counter]) ==
               Module.concat(TaggedEffect, :"Agent.Counter")

      assert TaggedEffect.sig([:state, :my_tag]) ==
               Module.concat(TaggedEffect, :"State.MyTag")
    end
  end

  describe "op atom naming" do
    test "snake_case function name becomes CamelCase op atom" do
      assert TaggedEffect.Get == Module.concat(TaggedEffect, :Get)
      assert TaggedEffect.Put == Module.concat(TaggedEffect, :Put)
      assert TaggedEffect.Modify == Module.concat(TaggedEffect, :Modify)
    end
  end
end
