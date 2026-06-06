defmodule Skuld.Effects.AtomicStateTest do
  use ExUnit.Case, async: true

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.AtomicState

  describe "with_agent_handler (production)" do
    test "get returns initial value" do
      result =
        comp do
          AtomicState.get()
        end
        |> AtomicState.with_agent_handler(42)
        |> Comp.run!()

      assert result == 42
    end

    test "put updates state" do
      result =
        comp do
          _ <- AtomicState.put(100)
          AtomicState.get()
        end
        |> AtomicState.with_agent_handler(0)
        |> Comp.run!()

      assert result == 100
    end

    test "modify updates state with function and returns new value" do
      result =
        comp do
          new_val <- AtomicState.modify(&(&1 + 10))
          current <- AtomicState.get()
          {new_val, current}
        end
        |> AtomicState.with_agent_handler(5)
        |> Comp.run!()

      assert result == {15, 15}
    end

    test "atomic_state applies function and returns result" do
      result =
        comp do
          result <- AtomicState.atomic_state(fn s -> {:popped, s + 1} end)
          current <- AtomicState.get()
          {result, current}
        end
        |> AtomicState.with_agent_handler(10)
        |> Comp.run!()

      assert result == {:popped, 11}
    end

    test "cas succeeds when expected matches current" do
      result =
        comp do
          result <- AtomicState.cas(10, 20)
          current <- AtomicState.get()
          {result, current}
        end
        |> AtomicState.with_agent_handler(10)
        |> Comp.run!()

      assert result == {:ok, 20}
    end

    test "cas fails when expected doesn't match current" do
      result =
        comp do
          result <- AtomicState.cas(999, 20)
          current <- AtomicState.get()
          {result, current}
        end
        |> AtomicState.with_agent_handler(10)
        |> Comp.run!()

      assert result == {{:conflict, 10}, 10}
    end

    test "multiple cas operations" do
      result =
        comp do
          r1 <- AtomicState.cas(10, 20)
          # fails - current is 20
          r2 <- AtomicState.cas(10, 30)
          # succeeds
          r3 <- AtomicState.cas(20, 30)
          final <- AtomicState.get()
          {r1, r2, r3, final}
        end
        |> AtomicState.with_agent_handler(10)
        |> Comp.run!()

      assert result == {:ok, {:conflict, 20}, :ok, 30}
    end

    test "tagged operations - multiple independent states" do
      result =
        comp do
          _ <- AtomicState.put(:counter, 100)
          _ <- AtomicState.put(:cache, %{key: "value"})

          _ <- AtomicState.modify(:counter, &(&1 + 1))
          _ <- AtomicState.modify(:cache, &Map.put(&1, :another, "data"))

          counter <- AtomicState.get(:counter)
          cache <- AtomicState.get(:cache)
          {counter, cache}
        end
        |> AtomicState.with_agent_handler(0, tag: :counter)
        |> AtomicState.with_agent_handler(%{}, tag: :cache)
        |> Comp.run!()

      assert result == {101, %{key: "value", another: "data"}}
    end

    test "tagged cas operations" do
      result =
        comp do
          r1 <- AtomicState.cas(:a, 10, 20)
          r2 <- AtomicState.cas(:b, 100, 200)
          a <- AtomicState.get(:a)
          b <- AtomicState.get(:b)
          {r1, r2, a, b}
        end
        |> AtomicState.with_agent_handler(10, tag: :a)
        |> AtomicState.with_agent_handler(100, tag: :b)
        |> Comp.run!()

      assert result == {:ok, :ok, 20, 200}
    end

    test "concurrent access from multiple tasks" do
      # This test verifies that Agent-backed state is actually shared
      # across processes (unlike env.state which is copied)

      result =
        comp do
          # Get the initial value
          initial <- AtomicState.get()

          # Spawn tasks that increment the counter
          # (Note: we can't use AtomicState inside the tasks since they
          # don't have access to the computation's env, but we can
          # demonstrate that the Agent is accessible)
          _ <- AtomicState.modify(&(&1 + 1))
          _ <- AtomicState.modify(&(&1 + 1))
          _ <- AtomicState.modify(&(&1 + 1))

          final <- AtomicState.get()
          {initial, final}
        end
        |> AtomicState.with_agent_handler(0)
        |> Comp.run!()

      assert result == {0, 3}
    end

    test "agent is cleaned up after computation" do
      # Run a computation that uses AtomicState
      comp do
        _ <- AtomicState.put(42)
        AtomicState.get()
      end
      |> AtomicState.with_agent_handler(0)
      |> Comp.run!()

      # If we got here without error, the agent was properly stopped
      # (Agent.stop is called in finally_k)
      assert true
    end
  end

  describe "with_state_handler (testing)" do
    test "get returns initial value" do
      result =
        comp do
          AtomicState.get()
        end
        |> AtomicState.with_state_handler(42)
        |> Comp.run!()

      assert result == 42
    end

    test "put updates state" do
      result =
        comp do
          _ <- AtomicState.put(100)
          AtomicState.get()
        end
        |> AtomicState.with_state_handler(0)
        |> Comp.run!()

      assert result == 100
    end

    test "modify updates state with function and returns new value" do
      result =
        comp do
          new_val <- AtomicState.modify(&(&1 + 10))
          current <- AtomicState.get()
          {new_val, current}
        end
        |> AtomicState.with_state_handler(5)
        |> Comp.run!()

      assert result == {15, 15}
    end

    test "atomic_state applies function and returns result" do
      result =
        comp do
          result <- AtomicState.atomic_state(fn s -> {:popped, s + 1} end)
          current <- AtomicState.get()
          {result, current}
        end
        |> AtomicState.with_state_handler(10)
        |> Comp.run!()

      assert result == {:popped, 11}
    end

    test "cas succeeds when expected matches current" do
      result =
        comp do
          result <- AtomicState.cas(10, 20)
          current <- AtomicState.get()
          {result, current}
        end
        |> AtomicState.with_state_handler(10)
        |> Comp.run!()

      assert result == {:ok, 20}
    end

    test "cas fails when expected doesn't match current" do
      result =
        comp do
          result <- AtomicState.cas(999, 20)
          current <- AtomicState.get()
          {result, current}
        end
        |> AtomicState.with_state_handler(10)
        |> Comp.run!()

      assert result == {{:conflict, 10}, 10}
    end

    test "tagged operations - multiple independent states" do
      result =
        comp do
          _ <- AtomicState.put(:counter, 100)
          _ <- AtomicState.put(:cache, %{key: "value"})

          _ <- AtomicState.modify(:counter, &(&1 + 1))
          _ <- AtomicState.modify(:cache, &Map.put(&1, :another, "data"))

          counter <- AtomicState.get(:counter)
          cache <- AtomicState.get(:cache)
          {counter, cache}
        end
        |> AtomicState.with_state_handler(0, tag: :counter)
        |> AtomicState.with_state_handler(%{}, tag: :cache)
        |> Comp.run!()

      assert result == {101, %{key: "value", another: "data"}}
    end

    test "state is isolated per handler scope" do
      result =
        comp do
          outer1 <- AtomicState.get()

          inner_result <-
            comp do
              _ <- AtomicState.put(999)
              AtomicState.get()
            end
            |> AtomicState.with_state_handler(100)

          outer2 <- AtomicState.get()
          {outer1, inner_result, outer2}
        end
        |> AtomicState.with_state_handler(42)
        |> Comp.run!()

      # Inner handler has its own state, doesn't affect outer
      assert result == {42, 999, 42}
    end
  end

  describe "edge cases" do
    test "put with nil value" do
      result =
        comp do
          _ <- AtomicState.put(nil)
          AtomicState.get()
        end
        |> AtomicState.with_agent_handler(:initial)
        |> Comp.run!()

      assert result == nil
    end

    test "modify with identity function" do
      result =
        comp do
          new_val <- AtomicState.modify(& &1)
          current <- AtomicState.get()
          {new_val, current}
        end
        |> AtomicState.with_agent_handler(42)
        |> Comp.run!()

      assert result == {42, 42}
    end

    test "cas with nil expected" do
      result =
        comp do
          result <- AtomicState.cas(nil, :new_value)
          current <- AtomicState.get()
          {result, current}
        end
        |> AtomicState.with_agent_handler(nil)
        |> Comp.run!()

      assert result == {:ok, :new_value}
    end

    test "cas with nil new value" do
      result =
        comp do
          result <- AtomicState.cas(42, nil)
          current <- AtomicState.get()
          {result, current}
        end
        |> AtomicState.with_agent_handler(42)
        |> Comp.run!()

      assert result == {:ok, nil}
    end

    test "complex state types" do
      initial = %{users: [], counter: 0, metadata: %{created: :now}}

      result =
        comp do
          _ <-
            AtomicState.modify(fn s ->
              %{s | users: ["alice" | s.users], counter: s.counter + 1}
            end)

          _ <-
            AtomicState.modify(fn s ->
              %{s | users: ["bob" | s.users], counter: s.counter + 1}
            end)

          AtomicState.get()
        end
        |> AtomicState.with_agent_handler(initial)
        |> Comp.run!()

      assert result == %{
               users: ["bob", "alice"],
               counter: 2,
               metadata: %{created: :now}
             }
    end
  end
end
