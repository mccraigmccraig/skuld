defmodule Skuld.CompTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Env

  describe "pure" do
    test "returns value" do
      comp = Comp.pure(42)
      assert {42, _env} = Comp.run(comp)
    end
  end

  describe "bind" do
    test "sequences computations" do
      comp =
        Comp.bind(Comp.pure(1), fn a ->
          Comp.bind(Comp.pure(2), fn b ->
            Comp.pure(a + b)
          end)
        end)

      assert {3, _env} = Comp.run(comp)
    end
  end

  describe "map" do
    test "transforms result" do
      comp = Comp.map(Comp.pure(5), &(&1 * 2))
      assert {10, _env} = Comp.run(comp)
    end
  end

  describe "sequence" do
    test "collects results" do
      comps = [Comp.pure(1), Comp.pure(2), Comp.pure(3)]
      comp = Comp.sequence(comps)
      assert {[1, 2, 3], _env} = Comp.run(comp)
    end

    test "empty list returns empty list" do
      comp = Comp.sequence([])
      assert {[], _env} = Comp.run(comp)
    end
  end

  describe "traverse" do
    test "maps and sequences" do
      comp = Comp.traverse([1, 2, 3], fn x -> Comp.pure(x * 2) end)
      assert {[2, 4, 6], _env} = Comp.run(comp)
    end
  end

  describe "each" do
    alias Skuld.Effects.Writer

    test "runs effects and returns :ok" do
      comp =
        Comp.each([1, 2, 3], fn x -> Writer.tell(x) end)
        |> Writer.with_handler([], output: fn result, log -> {result, log} end)

      assert {{:ok, [3, 2, 1]}, _env} = Comp.run(comp)
    end

    test "empty list returns :ok" do
      comp = Comp.each([], fn x -> Comp.pure(x) end)
      assert {:ok, _env} = Comp.run(comp)
    end

    test "discards individual results" do
      comp = Comp.each([1, 2, 3], fn x -> Comp.pure(x * 100) end)
      # Returns :ok, not [100, 200, 300]
      assert {:ok, _env} = Comp.run(comp)
    end
  end

  describe "then_do" do
    test "ignores first result" do
      comp = Comp.then_do(Comp.pure(:ignored), Comp.pure(:kept))
      assert {:kept, _env} = Comp.run(comp)
    end
  end

  describe "flatten" do
    test "flattens nested computation" do
      nested = Comp.pure(Comp.pure(42))
      comp = Comp.flatten(nested)
      assert {42, _env} = Comp.run(comp)
    end
  end

  describe "call/3 auto-lifting" do
    # Auto-lifting: non-computation values are automatically wrapped in pure()
    # This enables ergonomic patterns like:
    #   _ <- if condition, do: effect()  # nil auto-lifted when false
    #   x + 1  # final expression auto-lifted (no return needed)

    test "auto-lifts plain values" do
      {result, _env} = Comp.call(42, Env.new(), fn v, e -> {v, e} end)
      assert result == 42
    end

    test "auto-lifts nil" do
      {result, _env} = Comp.call(nil, Env.new(), fn v, e -> {v, e} end)
      assert result == nil
    end

    test "auto-lifts functions (treated as values, not computations)" do
      some_fn = fn _x -> :oops end
      {result, _env} = Comp.call(some_fn, Env.new(), fn v, e -> {v, e} end)
      assert result == some_fn
    end

    test "bind auto-lifts when continuation returns non-computation" do
      # This is now valid - :not_a_computation is auto-lifted
      comp = Comp.bind(Comp.pure(1), fn _a -> :not_a_computation end)
      {result, _env} = Comp.run(comp)
      assert result == :not_a_computation
    end

    test "run auto-lifts non-computation" do
      {result, _env} = Comp.run(:not_a_computation)
      assert result == :not_a_computation
    end

    test "flatten auto-lifts inner non-computation" do
      # Comp.pure(:some_value) yields :some_value
      # flatten then calls :some_value, which auto-lifts to pure(:some_value)
      nested = Comp.pure(:some_value)
      comp = Comp.flatten(nested)
      {result, _env} = Comp.run(comp)
      assert result == :some_value
    end
  end

  describe "exception handling" do
    alias Skuld.Comp.Throw, as: ThrowStruct
    alias Skuld.Effects.Throw

    test "raise is converted to Throw with kind: :error" do
      comp = fn _env, _k -> raise "boom" end

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "boom"} = error.payload
      assert is_list(error.stacktrace)
    end

    test "Elixir throw is converted to Throw with kind: :throw" do
      comp = fn _env, _k -> throw(:some_value) end

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :throw
      assert error.payload == :some_value
      assert is_list(error.stacktrace)
    end

    test "exit is converted to Throw with kind: :exit" do
      comp = fn _env, _k -> exit(:shutdown) end

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :exit
      assert error.payload == :shutdown
      assert is_list(error.stacktrace)
    end

    test "exception in bind is converted to Throw" do
      comp =
        Comp.bind(Comp.pure(1), fn _x ->
          fn _env, _k -> raise "in bind" end
        end)

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "in bind"} = error.payload
    end

    test "exception can be caught with catch_error" do
      comp =
        Throw.catch_error(
          fn _env, _k -> raise "caught me" end,
          fn error ->
            Comp.pure({:caught, error.kind, error.payload.message})
          end
        )
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:caught, :error, "caught me"} = result
    end

    test "Elixir throw can be caught with catch_error" do
      comp =
        Throw.catch_error(
          fn _env, _k -> throw(:thrown_value) end,
          fn error ->
            Comp.pure({:caught, error.kind, error.payload})
          end
        )
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:caught, :throw, :thrown_value} = result
    end

    test "nested exceptions - inner caught, outer continues" do
      inner =
        Throw.catch_error(
          fn _env, _k -> raise "inner error" end,
          fn _error -> Comp.pure(:recovered) end
        )

      comp =
        Comp.bind(inner, fn value -> Comp.pure({:continued, value}) end)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:continued, :recovered} = result
    end

    test "exception after recovery propagates" do
      comp =
        Throw.catch_error(
          Throw.catch_error(
            fn _env, _k -> raise "first" end,
            fn _error ->
              # Recovery raises another exception
              fn _env, _k -> raise "in recovery" end
            end
          ),
          fn error ->
            Comp.pure({:outer_caught, error.payload.message})
          end
        )
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:outer_caught, "in recovery"} = result
    end

    test "stacktrace is captured" do
      comp = fn _env, _k ->
        raise "with stacktrace"
      end

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert is_list(error.stacktrace)
      assert error.stacktrace != []
      # Stacktrace entries are tuples {module, function, arity_or_args, location}
      assert Enum.all?(error.stacktrace, &is_tuple/1)
    end

    test "exception in effect handler is converted to Throw" do
      # Create a handler that raises
      raising_handler = fn _args, _env, _k ->
        raise "handler exploded"
      end

      # Use low-level Env.with_handler for testing custom handlers
      comp =
        Comp.effect(:test_effect, :some_args)
        |> Comp.with_handler(:test_effect, raising_handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "handler exploded"} = error.payload
    end

    test "exception in effect handler can be caught" do
      raising_handler = fn _args, _env, _k ->
        raise "handler error"
      end

      comp =
        Throw.catch_error(
          Comp.effect(:test_effect, :args),
          fn error -> Comp.pure({:caught_handler_error, error.payload.message}) end
        )
        |> Comp.with_handler(:test_effect, raising_handler)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:caught_handler_error, "handler error"} = result
    end
  end

  describe "with_handler/3 scoped handlers" do
    alias Skuld.Effects.State

    # Helper to create a state-scoping setup function
    # State now uses {State, tag} as key, with default tag being State module
    @state_key {State, State}

    defp state_scope(initial) do
      fn env ->
        previous = Env.get_state(env, @state_key)
        modified = Env.put_state(env, @state_key, initial)
        finally_k = fn value, e -> {value, Env.put_state(e, @state_key, previous)} end
        {modified, finally_k}
      end
    end

    test "installs handler for scope duration" do
      # No handler in outer env

      # Inner comp uses scoped State handler
      inner =
        State.get()
        |> Comp.scoped(state_scope(42))
        |> Comp.with_handler(State, &State.handle/3)

      {result, _env} = Comp.run(inner)

      assert result == 42
    end

    test "handler is removed after scope exits" do
      comp =
        Comp.bind(
          State.get()
          |> Comp.scoped(state_scope(10))
          |> Comp.with_handler(State, &State.handle/3),
          fn inner_result ->
            # After handle scope, State handler should be gone
            # Trying to use State.get() here would fail
            Comp.pure({:inner, inner_result})
          end
        )

      {result, final_env} = Comp.run(comp)

      assert {:inner, 10} = result
      # Handler should be removed
      assert Env.get_handler(final_env, State) == nil
    end

    test "shadows outer handler and restores it" do
      # Use with_handler for outer State
      comp =
        Comp.bind(State.get(), fn outer_before ->
          Comp.bind(
            # Inner scope with its own State, initial 0
            Comp.bind(State.get(), fn inner_val ->
              Comp.bind(State.put(inner_val + 1), fn _ ->
                State.get()
              end)
            end)
            |> Comp.scoped(state_scope(0))
            |> Comp.with_handler(State, &State.handle/3),
            fn inner_result ->
              Comp.bind(State.get(), fn outer_after ->
                Comp.pure({outer_before, inner_result, outer_after})
              end)
            end
          )
        end)
        |> State.with_handler(100)

      {result, _env} = Comp.run(comp)

      # outer_before: 100, inner did 0 -> 1, outer_after: still 100
      assert {100, 1, 100} = result
    end

    test "nested scoped handlers work correctly" do
      comp =
        Comp.bind(State.get(), fn level1 ->
          Comp.bind(
            State.get()
            |> Comp.scoped(state_scope(2))
            |> Comp.with_handler(State, &State.handle/3),
            fn level2 ->
              Comp.bind(State.get(), fn level1_after ->
                Comp.pure({level1, level2, level1_after})
              end)
            end
          )
        end)
        |> Comp.scoped(state_scope(1))
        |> Comp.with_handler(State, &State.handle/3)

      {result, _env} = Comp.run(comp)

      # level1: 1, level2: 2, level1_after: still 1
      assert {1, 2, 1} = result
    end

    test "scoped handler cleanup on throw" do
      alias Skuld.Effects.Throw

      comp =
        Throw.catch_error(
          Comp.bind(State.get(), fn _outer_before ->
            Comp.bind(
              Comp.bind(State.put(42), fn _ ->
                # Throw from inside scoped handler
                Throw.throw(:inner_error)
              end)
              |> Comp.scoped(state_scope(0))
              |> Comp.with_handler(State, &State.handle/3),
              fn _ ->
                # Never reached
                Comp.pure(:unreachable)
              end
            )
          end),
          fn _error ->
            # After throw, outer State should be restored
            Comp.bind(State.get(), fn outer_after ->
              Comp.pure({:caught, outer_after})
            end)
          end
        )
        |> State.with_handler(100)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      # Outer state (100) should be preserved despite inner throw
      assert {:caught, 100} = result
    end
  end

  describe "with_scoped_state :suspend option" do
    alias Skuld.Comp.Suspend
    alias Skuld.Effects.{State, Yield}

    @state_key {State, State}

    test "suspend option decorates Suspend.data when yielding" do
      comp =
        Yield.yield(:hello)
        |> Comp.with_scoped_state(@state_key, 42,
          suspend: fn s, env ->
            state = Env.get_state(env, @state_key)
            data = s.data || %{}
            {%{s | data: Map.put(data, :my_state, state)}, env}
          end
        )
        |> State.with_handler(0)
        |> Yield.with_handler()

      {%Suspend{value: :hello, data: data}, _env} = Comp.run(comp)

      assert data == %{my_state: 42}
    end

    test "suspend decorations compose - inner decorates first" do
      comp =
        Yield.yield(:hello)
        |> Comp.with_scoped_state(:inner_key, :inner_value,
          suspend: fn s, env ->
            state = Env.get_state(env, :inner_key)
            data = s.data || %{}
            {%{s | data: Map.put(data, :inner, state)}, env}
          end
        )
        |> Comp.with_scoped_state(:outer_key, :outer_value,
          suspend: fn s, env ->
            state = Env.get_state(env, :outer_key)
            data = s.data || %{}
            {%{s | data: Map.put(data, :outer, state)}, env}
          end
        )
        |> Yield.with_handler()

      {%Suspend{value: :hello, data: data}, _env} = Comp.run(comp)

      # Both decorations should be present
      assert data == %{inner: :inner_value, outer: :outer_value}
    end

    test "suspend option is restored after scope exits" do
      # Create an inner scope with suspend decoration
      inner =
        Yield.yield(:inner_yield)
        |> Comp.with_scoped_state(:inner_key, :inner_value,
          suspend: fn s, env ->
            data = s.data || %{}
            {%{s | data: Map.put(data, :from_inner, true)}, env}
          end
        )

      # Outer scope without suspend decoration
      comp =
        Comp.bind(inner, fn input ->
          # After inner scope, the inner's suspend transform should be gone
          # This yield should NOT have :from_inner decoration
          Yield.yield({:outer_yield, input})
        end)
        |> Yield.with_handler()

      # First run - get inner yield
      {%Suspend{value: :inner_yield, data: inner_data, resume: resume}, _env} = Comp.run(comp)
      assert inner_data == %{from_inner: true}

      # Resume - inner scope exits, then outer yield happens
      {%Suspend{value: {:outer_yield, :resumed}, data: outer_data}, _env} = resume.(:resumed)

      # Outer yield should NOT have the inner decoration
      assert outer_data == nil
    end

    test "without suspend option, Suspend.data remains nil" do
      comp =
        Yield.yield(:hello)
        |> Comp.with_scoped_state(@state_key, 42)
        |> State.with_handler(0)
        |> Yield.with_handler()

      {%Suspend{value: :hello, data: data}, _env} = Comp.run(comp)

      assert data == nil
    end
  end
end
