defmodule Skuld.Effects.TaggedReaderTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Effects.TaggedReader

  describe "ask" do
    test "reads environment value for tag" do
      comp = TaggedReader.ask(:config) |> TaggedReader.with_handler(:config, :config_value)
      assert {:config_value, _} = Comp.run(comp)
    end

    test "multiple tags are independent" do
      comp =
        Comp.bind(TaggedReader.ask(:db), fn db ->
          Comp.bind(TaggedReader.ask(:cache), fn cache ->
            Comp.pure({db, cache})
          end)
        end)
        |> TaggedReader.with_handler(:db, %{host: "db.local"})
        |> TaggedReader.with_handler(:cache, %{host: "cache.local"})

      {{%{host: "db.local"}, %{host: "cache.local"}}, _} = Comp.run(comp)
    end
  end

  describe "asks" do
    test "applies function to environment for tag" do
      comp =
        TaggedReader.asks(:config, & &1.count)
        |> TaggedReader.with_handler(:config, %{name: "test", count: 42})

      assert {42, _} = Comp.run(comp)
    end
  end

  describe "local" do
    test "modifies environment for sub-computation" do
      comp =
        Comp.bind(TaggedReader.ask(:num), fn before ->
          TaggedReader.local(
            :num,
            &(&1 * 2),
            Comp.bind(TaggedReader.ask(:num), fn during ->
              Comp.bind(TaggedReader.ask(:num), fn after_local ->
                # after_local is still inside local, so still modified
                Comp.pure({before, during, after_local})
              end)
            end)
          )
        end)
        |> TaggedReader.with_handler(:num, 10)

      # Note: after_local is INSIDE the local, so it sees modified value
      assert {{10, 20, 20}, _} = Comp.run(comp)
    end

    test "restores environment after scope exits" do
      inner = TaggedReader.local(:num, &(&1 * 2), TaggedReader.ask(:num))

      comp =
        Comp.bind(inner, fn _during ->
          # After local completes
          TaggedReader.ask(:num)
        end)
        |> TaggedReader.with_handler(:num, 10)

      assert {10, _} = Comp.run(comp)
    end

    test "local on one tag does not affect other tags" do
      comp =
        TaggedReader.local(
          :a,
          &(&1 * 10),
          Comp.bind(TaggedReader.ask(:a), fn a ->
            Comp.bind(TaggedReader.ask(:b), fn b ->
              Comp.pure({a, b})
            end)
          end)
        )
        |> TaggedReader.with_handler(:a, 1)
        |> TaggedReader.with_handler(:b, 2)

      # :a is modified to 10, :b stays 2
      assert {{10, 2}, _} = Comp.run(comp)
    end
  end

  describe "with_handler/3" do
    test "installs handler and context for computation" do
      comp =
        TaggedReader.asks(:config, & &1.name)
        |> TaggedReader.with_handler(:config, %{name: "test"})

      {result, _env} = Comp.run(comp)
      assert result == "test"
    end

    test "shadows outer handler of same tag and restores it" do
      comp =
        Comp.bind(TaggedReader.ask(:ctx), fn outer_before ->
          inner = TaggedReader.ask(:ctx) |> TaggedReader.with_handler(:ctx, :inner)

          Comp.bind(inner, fn inner_result ->
            Comp.bind(TaggedReader.ask(:ctx), fn outer_after ->
              Comp.pure({outer_before, inner_result, outer_after})
            end)
          end)
        end)
        |> TaggedReader.with_handler(:ctx, :outer)

      {result, _env} = Comp.run(comp)

      assert {:outer, :inner, :outer} = result
    end

    test "cleanup on throw" do
      alias Skuld.Effects.Throw

      comp =
        Throw.catch_error(
          Comp.bind(
            Throw.throw(:error) |> TaggedReader.with_handler(:ctx, :inner),
            fn _ -> Comp.pure(:unreachable) end
          ),
          fn _error ->
            Comp.bind(TaggedReader.ask(:ctx), fn outer_after ->
              Comp.pure({:caught, outer_after})
            end)
          end
        )
        |> TaggedReader.with_handler(:ctx, :outer)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:caught, :outer} = result
    end

    test "handler removed after scope when no previous handler" do
      comp =
        Comp.bind(
          TaggedReader.ask(:ctx) |> TaggedReader.with_handler(:ctx, :config),
          fn inner_result ->
            Comp.pure({:done, inner_result})
          end
        )

      {result, final_env} = Comp.run(comp)

      assert {:done, :config} = result
      # State for tag should be removed
      assert Env.get_state(final_env, {TaggedReader, :ctx}) == nil
    end

    test "composable with untagged Reader" do
      alias Skuld.Effects.Reader

      comp =
        Comp.bind(TaggedReader.ask(:tagged), fn tagged ->
          Comp.bind(Reader.ask(), fn untagged ->
            Comp.pure({tagged, untagged})
          end)
        end)
        |> TaggedReader.with_handler(:tagged, :tagged_value)
        |> Reader.with_handler(:untagged_value)

      {result, _env} = Comp.run(comp)

      assert {:tagged_value, :untagged_value} = result
    end
  end
end
