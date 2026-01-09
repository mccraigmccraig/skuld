defmodule Skuld.Effects.StateTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Effects.State

  describe "get (default tag)" do
    test "returns current state" do
      comp = State.get() |> State.with_handler(42)
      assert {42, _} = Comp.run(comp)
    end
  end

  describe "get (explicit tag)" do
    test "returns current state for tag" do
      comp = State.get(:counter) |> State.with_handler(42, tag: :counter)
      assert {42, _} = Comp.run(comp)
    end

    test "multiple tags are independent" do
      comp =
        Comp.bind(State.get(:a), fn a ->
          Comp.bind(State.get(:b), fn b ->
            Comp.pure({a, b})
          end)
        end)
        |> State.with_handler(1, tag: :a)
        |> State.with_handler(2, tag: :b)

      assert {{1, 2}, _} = Comp.run(comp)
    end
  end

  describe "put (default tag)" do
    test "updates state" do
      comp =
        Comp.bind(State.put(100), fn _ ->
          State.get()
        end)
        |> State.with_handler(0)

      assert {100, final_env} = Comp.run(comp)
      # Note: State is scoped, so it's removed after with_handler exits
      assert State.get_state(final_env) == nil
    end
  end

  describe "put (explicit tag)" do
    test "updates state for tag" do
      comp =
        Comp.bind(State.put(:counter, 100), fn _ ->
          State.get(:counter)
        end)
        |> State.with_handler(0, tag: :counter)

      assert {100, final_env} = Comp.run(comp)
      # State is scoped, so it's removed after with_handler exits
      assert State.get_state(final_env, :counter) == nil
    end

    test "put on one tag does not affect other tags" do
      comp =
        Comp.bind(State.put(:a, 100), fn _ ->
          Comp.bind(State.get(:a), fn a ->
            Comp.bind(State.get(:b), fn b ->
              Comp.pure({a, b})
            end)
          end)
        end)
        |> State.with_handler(0, tag: :a)
        |> State.with_handler(2, tag: :b)

      assert {{100, 2}, _} = Comp.run(comp)
    end
  end

  describe "modify (default tag)" do
    test "transforms state and returns old value" do
      comp =
        Comp.bind(State.modify(&(&1 + 5)), fn old ->
          Comp.bind(State.get(), fn new ->
            Comp.pure({old, new})
          end)
        end)
        |> State.with_handler(10)

      assert {{10, 15}, _} = Comp.run(comp)
    end
  end

  describe "modify (explicit tag)" do
    test "transforms state and returns old value" do
      comp =
        Comp.bind(State.modify(:counter, &(&1 + 5)), fn old ->
          Comp.bind(State.get(:counter), fn new ->
            Comp.pure({old, new})
          end)
        end)
        |> State.with_handler(10, tag: :counter)

      assert {{10, 15}, _} = Comp.run(comp)
    end
  end

  describe "gets (default tag)" do
    test "applies function to state" do
      comp = State.gets(& &1.count) |> State.with_handler(%{count: 42, name: "test"})
      assert {42, _} = Comp.run(comp)
    end
  end

  describe "gets (explicit tag)" do
    test "applies function to state for tag" do
      comp =
        State.gets(:config, & &1.count)
        |> State.with_handler(%{count: 42, name: "test"}, tag: :config)

      assert {42, _} = Comp.run(comp)
    end
  end

  describe "state threading (default tag)" do
    test "threads state through computation" do
      comp =
        Comp.bind(State.modify(&(&1 + 1)), fn _ ->
          Comp.bind(State.modify(&(&1 + 1)), fn _ ->
            Comp.bind(State.modify(&(&1 + 1)), fn _ ->
              State.get()
            end)
          end)
        end)
        |> State.with_handler(0)

      assert {3, _} = Comp.run(comp)
    end
  end

  describe "state threading (explicit tags)" do
    test "threads state through computation for each tag independently" do
      comp =
        Comp.bind(State.modify(:a, &(&1 + 1)), fn _ ->
          Comp.bind(State.modify(:b, &(&1 + 10)), fn _ ->
            Comp.bind(State.modify(:a, &(&1 + 1)), fn _ ->
              Comp.bind(State.modify(:b, &(&1 + 10)), fn _ ->
                Comp.bind(State.get(:a), fn a ->
                  Comp.bind(State.get(:b), fn b ->
                    Comp.pure({a, b})
                  end)
                end)
              end)
            end)
          end)
        end)
        |> State.with_handler(0, tag: :a)
        |> State.with_handler(0, tag: :b)

      assert {{2, 20}, _} = Comp.run(comp)
    end
  end

  describe "with_handler (default tag)" do
    test "installs handler and state for computation" do
      # No handler in env - State.with_handler provides everything

      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            State.get()
          end)
        end)
        |> State.with_handler(42)

      {result, _env} = Comp.run(comp)
      assert result == 43
    end

    test "shadows outer handler and restores it" do
      comp =
        Comp.bind(State.get(), fn outer_before ->
          inner_comp =
            Comp.bind(State.get(), fn inner_val ->
              Comp.bind(State.put(inner_val + 1), fn _ ->
                State.get()
              end)
            end)
            |> State.with_handler(0)

          Comp.bind(inner_comp, fn inner_result ->
            Comp.bind(State.get(), fn outer_after ->
              Comp.pure({outer_before, inner_result, outer_after})
            end)
          end)
        end)
        |> State.with_handler(100)

      {result, _env} = Comp.run(comp)

      # outer: 100, inner: 0->1, outer still 100
      assert {100, 1, 100} = result
    end

    test "nested scoped handlers work correctly" do
      comp =
        Comp.bind(State.get(), fn level1 ->
          inner = State.get() |> State.with_handler(2)

          Comp.bind(inner, fn level2 ->
            Comp.bind(State.get(), fn level1_after ->
              Comp.pure({level1, level2, level1_after})
            end)
          end)
        end)
        |> State.with_handler(1)

      {result, _env} = Comp.run(comp)

      assert {1, 2, 1} = result
    end

    test "cleanup on throw" do
      alias Skuld.Effects.Throw

      comp =
        Throw.catch_error(
          Comp.bind(
            Comp.bind(State.put(42), fn _ ->
              Throw.throw(:inner_error)
            end)
            |> State.with_handler(0),
            fn _ -> Comp.pure(:unreachable) end
          ),
          fn _error ->
            Comp.bind(State.get(), fn outer_after ->
              Comp.pure({:caught, outer_after})
            end)
          end
        )
        |> State.with_handler(100)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      # Outer state (100) preserved despite inner throw
      assert {:caught, 100} = result
    end

    test "handler removed after scope when no previous handler" do
      comp =
        Comp.bind(
          State.get() |> State.with_handler(10),
          fn inner_result ->
            Comp.pure({:done, inner_result})
          end
        )

      {result, final_env} = Comp.run(comp)

      assert {:done, 10} = result
      # Handler should be removed
      assert Env.get_handler(final_env, State) == nil
      # State should be removed (default tag key)
      assert Env.get_state(final_env, {State, State}) == nil
    end

    test "composable - pipe multiple scoped handlers" do
      comp =
        Comp.bind(State.get(), fn s ->
          Comp.bind(Skuld.Effects.Reader.ask(), fn r ->
            Comp.pure({s, r})
          end)
        end)
        |> Skuld.Effects.Reader.with_handler(:config)
        |> State.with_handler(42)

      {result, _env} = Comp.run(comp)

      assert {42, :config} = result
    end

    test "output includes final state in result" do
      comp =
        Comp.bind(State.put(10), fn _ ->
          Comp.bind(State.modify(&(&1 * 2)), fn _ ->
            Comp.pure(:done)
          end)
        end)
        |> State.with_handler(0, output: fn result, state -> {result, state} end)

      {result, _env} = Comp.run(comp)

      assert {:done, 20} = result
    end

    test "output with custom transformation" do
      comp =
        Comp.bind(State.modify(&(&1 + 1)), fn _ ->
          Comp.bind(State.modify(&(&1 + 1)), fn _ ->
            State.get()
          end)
        end)
        |> State.with_handler(0,
          output: fn result, state -> %{result: result, final_state: state} end
        )

      {result, _env} = Comp.run(comp)

      assert %{result: 2, final_state: 2} = result
    end
  end

  describe "with_handler (explicit tag)" do
    test "installs handler and state for computation" do
      comp =
        Comp.bind(State.get(:counter), fn x ->
          Comp.bind(State.put(:counter, x + 1), fn _ ->
            State.get(:counter)
          end)
        end)
        |> State.with_handler(42, tag: :counter)

      {result, _env} = Comp.run(comp)
      assert result == 43
    end

    test "shadows outer handler of same tag and restores it" do
      comp =
        Comp.bind(State.get(:s), fn outer_before ->
          inner_comp =
            Comp.bind(State.get(:s), fn inner_val ->
              Comp.bind(State.put(:s, inner_val + 1), fn _ ->
                State.get(:s)
              end)
            end)
            |> State.with_handler(0, tag: :s)

          Comp.bind(inner_comp, fn inner_result ->
            Comp.bind(State.get(:s), fn outer_after ->
              Comp.pure({outer_before, inner_result, outer_after})
            end)
          end)
        end)
        |> State.with_handler(100, tag: :s)

      {result, _env} = Comp.run(comp)

      # outer: 100, inner: 0->1, outer still 100
      assert {100, 1, 100} = result
    end

    test "nested handlers for different tags work correctly" do
      comp =
        Comp.bind(State.get(:outer), fn outer_val ->
          inner =
            Comp.bind(State.get(:inner), fn inner_val ->
              Comp.bind(State.get(:outer), fn outer_in_inner ->
                Comp.pure({inner_val, outer_in_inner})
              end)
            end)
            |> State.with_handler(2, tag: :inner)

          Comp.bind(inner, fn {inner_val, outer_in_inner} ->
            Comp.pure({outer_val, inner_val, outer_in_inner})
          end)
        end)
        |> State.with_handler(1, tag: :outer)

      {result, _env} = Comp.run(comp)

      assert {1, 2, 1} = result
    end

    test "cleanup on throw" do
      alias Skuld.Effects.Throw

      comp =
        Throw.catch_error(
          Comp.bind(
            Comp.bind(State.put(:s, 42), fn _ ->
              Throw.throw(:inner_error)
            end)
            |> State.with_handler(0, tag: :s),
            fn _ -> Comp.pure(:unreachable) end
          ),
          fn _error ->
            Comp.bind(State.get(:s), fn outer_after ->
              Comp.pure({:caught, outer_after})
            end)
          end
        )
        |> State.with_handler(100, tag: :s)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      # Outer state (100) preserved despite inner throw
      assert {:caught, 100} = result
    end

    test "handler removed after scope when no previous handler" do
      comp =
        Comp.bind(
          State.get(:s) |> State.with_handler(10, tag: :s),
          fn inner_result ->
            Comp.pure({:done, inner_result})
          end
        )

      {result, final_env} = Comp.run(comp)

      assert {:done, 10} = result
      # State for tag should be removed
      assert Env.get_state(final_env, {State, :s}) == nil
    end

    test "composable - pipe multiple tagged handlers" do
      alias Skuld.Effects.Reader

      comp =
        Comp.bind(State.get(:counter), fn counter ->
          Comp.bind(State.get(:name), fn name ->
            Comp.bind(Reader.ask(), fn config ->
              Comp.pure({counter, name, config})
            end)
          end)
        end)
        |> State.with_handler(42, tag: :counter)
        |> State.with_handler("alice", tag: :name)
        |> Reader.with_handler(:config)

      {result, _env} = Comp.run(comp)

      assert {42, "alice", :config} = result
    end

    test "output includes final state in result" do
      comp =
        Comp.bind(State.put(:counter, 10), fn _ ->
          Comp.bind(State.modify(:counter, &(&1 * 2)), fn _ ->
            Comp.pure(:done)
          end)
        end)
        |> State.with_handler(0, tag: :counter, output: fn result, state -> {result, state} end)

      {result, _env} = Comp.run(comp)

      assert {:done, 20} = result
    end

    test "output with custom transformation" do
      comp =
        Comp.bind(State.modify(:cnt, &(&1 + 1)), fn _ ->
          Comp.bind(State.modify(:cnt, &(&1 + 1)), fn _ ->
            State.get(:cnt)
          end)
        end)
        |> State.with_handler(0,
          tag: :cnt,
          output: fn result, state -> %{result: result, final: state} end
        )

      {result, _env} = Comp.run(comp)

      assert %{result: 2, final: 2} = result
    end

    test "default tag and explicit tags don't interfere" do
      comp =
        Comp.bind(State.get(), fn default ->
          Comp.bind(State.get(:explicit), fn explicit ->
            Comp.pure({default, explicit})
          end)
        end)
        |> State.with_handler(:default_value)
        |> State.with_handler(:explicit_value, tag: :explicit)

      {result, _env} = Comp.run(comp)

      assert {:default_value, :explicit_value} = result
    end
  end
end
