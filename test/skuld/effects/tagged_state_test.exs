defmodule Skuld.Effects.TaggedStateTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Effects.TaggedState

  describe "get" do
    test "returns current state for tag" do
      comp = TaggedState.get(:counter) |> TaggedState.with_handler(:counter, 42)
      assert {42, _} = Comp.run(comp)
    end

    test "multiple tags are independent" do
      comp =
        Comp.bind(TaggedState.get(:a), fn a ->
          Comp.bind(TaggedState.get(:b), fn b ->
            Comp.pure({a, b})
          end)
        end)
        |> TaggedState.with_handler(:a, 1)
        |> TaggedState.with_handler(:b, 2)

      assert {{1, 2}, _} = Comp.run(comp)
    end
  end

  describe "put" do
    test "updates state for tag" do
      comp =
        Comp.bind(TaggedState.put(:counter, 100), fn _ ->
          TaggedState.get(:counter)
        end)
        |> TaggedState.with_handler(:counter, 0)

      assert {100, final_env} = Comp.run(comp)
      # State is scoped, so it's removed after with_handler exits
      assert TaggedState.get_state(final_env, :counter) == nil
    end

    test "put on one tag does not affect other tags" do
      comp =
        Comp.bind(TaggedState.put(:a, 100), fn _ ->
          Comp.bind(TaggedState.get(:a), fn a ->
            Comp.bind(TaggedState.get(:b), fn b ->
              Comp.pure({a, b})
            end)
          end)
        end)
        |> TaggedState.with_handler(:a, 0)
        |> TaggedState.with_handler(:b, 2)

      assert {{100, 2}, _} = Comp.run(comp)
    end
  end

  describe "modify" do
    test "transforms state and returns old value" do
      comp =
        Comp.bind(TaggedState.modify(:counter, &(&1 + 5)), fn old ->
          Comp.bind(TaggedState.get(:counter), fn new ->
            Comp.pure({old, new})
          end)
        end)
        |> TaggedState.with_handler(:counter, 10)

      assert {{10, 15}, _} = Comp.run(comp)
    end
  end

  describe "gets" do
    test "applies function to state for tag" do
      comp =
        TaggedState.gets(:config, & &1.count)
        |> TaggedState.with_handler(:config, %{count: 42, name: "test"})

      assert {42, _} = Comp.run(comp)
    end
  end

  describe "state threading" do
    test "threads state through computation for each tag independently" do
      comp =
        Comp.bind(TaggedState.modify(:a, &(&1 + 1)), fn _ ->
          Comp.bind(TaggedState.modify(:b, &(&1 + 10)), fn _ ->
            Comp.bind(TaggedState.modify(:a, &(&1 + 1)), fn _ ->
              Comp.bind(TaggedState.modify(:b, &(&1 + 10)), fn _ ->
                Comp.bind(TaggedState.get(:a), fn a ->
                  Comp.bind(TaggedState.get(:b), fn b ->
                    Comp.pure({a, b})
                  end)
                end)
              end)
            end)
          end)
        end)
        |> TaggedState.with_handler(:a, 0)
        |> TaggedState.with_handler(:b, 0)

      assert {{2, 20}, _} = Comp.run(comp)
    end
  end

  describe "with_handler/3" do
    test "installs handler and state for computation" do
      comp =
        Comp.bind(TaggedState.get(:counter), fn x ->
          Comp.bind(TaggedState.put(:counter, x + 1), fn _ ->
            TaggedState.get(:counter)
          end)
        end)
        |> TaggedState.with_handler(:counter, 42)

      {result, _env} = Comp.run(comp)
      assert result == 43
    end

    test "shadows outer handler of same tag and restores it" do
      comp =
        Comp.bind(TaggedState.get(:s), fn outer_before ->
          inner_comp =
            Comp.bind(TaggedState.get(:s), fn inner_val ->
              Comp.bind(TaggedState.put(:s, inner_val + 1), fn _ ->
                TaggedState.get(:s)
              end)
            end)
            |> TaggedState.with_handler(:s, 0)

          Comp.bind(inner_comp, fn inner_result ->
            Comp.bind(TaggedState.get(:s), fn outer_after ->
              Comp.pure({outer_before, inner_result, outer_after})
            end)
          end)
        end)
        |> TaggedState.with_handler(:s, 100)

      {result, _env} = Comp.run(comp)

      # outer: 100, inner: 0->1, outer still 100
      assert {100, 1, 100} = result
    end

    test "nested handlers for different tags work correctly" do
      comp =
        Comp.bind(TaggedState.get(:outer), fn outer_val ->
          inner =
            Comp.bind(TaggedState.get(:inner), fn inner_val ->
              Comp.bind(TaggedState.get(:outer), fn outer_in_inner ->
                Comp.pure({inner_val, outer_in_inner})
              end)
            end)
            |> TaggedState.with_handler(:inner, 2)

          Comp.bind(inner, fn {inner_val, outer_in_inner} ->
            Comp.pure({outer_val, inner_val, outer_in_inner})
          end)
        end)
        |> TaggedState.with_handler(:outer, 1)

      {result, _env} = Comp.run(comp)

      assert {1, 2, 1} = result
    end

    test "cleanup on throw" do
      alias Skuld.Effects.Throw

      comp =
        Throw.catch_error(
          Comp.bind(
            Comp.bind(TaggedState.put(:s, 42), fn _ ->
              Throw.throw(:inner_error)
            end)
            |> TaggedState.with_handler(:s, 0),
            fn _ -> Comp.pure(:unreachable) end
          ),
          fn _error ->
            Comp.bind(TaggedState.get(:s), fn outer_after ->
              Comp.pure({:caught, outer_after})
            end)
          end
        )
        |> TaggedState.with_handler(:s, 100)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      # Outer state (100) preserved despite inner throw
      assert {:caught, 100} = result
    end

    test "handler removed after scope when no previous handler" do
      comp =
        Comp.bind(
          TaggedState.get(:s) |> TaggedState.with_handler(:s, 10),
          fn inner_result ->
            Comp.pure({:done, inner_result})
          end
        )

      {result, final_env} = Comp.run(comp)

      assert {:done, 10} = result
      # State for tag should be removed
      assert Env.get_state(final_env, {TaggedState, :s}) == nil
    end

    test "composable with untagged State" do
      alias Skuld.Effects.State

      comp =
        Comp.bind(TaggedState.get(:tagged), fn tagged ->
          Comp.bind(State.get(), fn untagged ->
            Comp.pure({tagged, untagged})
          end)
        end)
        |> TaggedState.with_handler(:tagged, :tagged_value)
        |> State.with_handler(:untagged_value)

      {result, _env} = Comp.run(comp)

      assert {:tagged_value, :untagged_value} = result
    end

    test "composable - pipe multiple tagged handlers" do
      alias Skuld.Effects.Reader

      comp =
        Comp.bind(TaggedState.get(:counter), fn counter ->
          Comp.bind(TaggedState.get(:name), fn name ->
            Comp.bind(Reader.ask(), fn config ->
              Comp.pure({counter, name, config})
            end)
          end)
        end)
        |> TaggedState.with_handler(:counter, 42)
        |> TaggedState.with_handler(:name, "alice")
        |> Reader.with_handler(:config)

      {result, _env} = Comp.run(comp)

      assert {42, "alice", :config} = result
    end

    test "output includes final state in result" do
      comp =
        Comp.bind(TaggedState.put(:counter, 10), fn _ ->
          Comp.bind(TaggedState.modify(:counter, &(&1 * 2)), fn _ ->
            Comp.pure(:done)
          end)
        end)
        |> TaggedState.with_handler(:counter, 0,
          output: fn result, state -> {result, state} end
        )

      {result, _env} = Comp.run(comp)

      assert {:done, 20} = result
    end

    test "output with custom transformation" do
      comp =
        Comp.bind(TaggedState.modify(:cnt, &(&1 + 1)), fn _ ->
          Comp.bind(TaggedState.modify(:cnt, &(&1 + 1)), fn _ ->
            TaggedState.get(:cnt)
          end)
        end)
        |> TaggedState.with_handler(:cnt, 0,
          output: fn result, state -> %{result: result, final: state} end
        )

      {result, _env} = Comp.run(comp)

      assert %{result: 2, final: 2} = result
    end
  end
end
