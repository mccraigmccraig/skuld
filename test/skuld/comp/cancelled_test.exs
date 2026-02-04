defmodule Skuld.Comp.CancelledTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Cancelled
  alias Skuld.Comp.Env
  alias Skuld.Comp.ISentinel
  alias Skuld.Comp.ExternalSuspend
  alias Skuld.Effects.State
  alias Skuld.Effects.Yield

  describe "Cancelled struct" do
    test "can be created with a reason" do
      cancelled = %Cancelled{reason: :timeout}
      assert cancelled.reason == :timeout
    end

    test "implements ISentinel protocol" do
      cancelled = %Cancelled{reason: :test}
      assert ISentinel.sentinel?(cancelled) == true
    end

    test "is categorized as error sentinel" do
      cancelled = %Cancelled{reason: :test}
      assert ISentinel.error?(cancelled) == true
      assert ISentinel.suspend?(cancelled) == false
    end

    test "is not resumable" do
      cancelled = %Cancelled{reason: :test}
      assert ISentinel.get_resume(cancelled) == nil
    end

    test "with_resume returns unchanged" do
      cancelled = %Cancelled{reason: :test}
      resume_fn = fn _input -> {:result, Env.new()} end
      assert ISentinel.with_resume(cancelled, resume_fn) == cancelled
    end

    test "serializable_payload returns reason" do
      cancelled = %Cancelled{reason: {:complex, :reason}}
      assert ISentinel.serializable_payload(cancelled) == %{reason: {:complex, :reason}}
    end

    test "run! raises with reason" do
      cancelled = %Cancelled{reason: :user_abort}

      assert_raise RuntimeError, "Computation cancelled: :user_abort", fn ->
        ISentinel.run!(cancelled)
      end
    end
  end

  describe "ISentinel.run/2 for Cancelled" do
    test "invokes leave_scope" do
      # Track whether leave_scope was called
      test_pid = self()

      leave_scope = fn result, env ->
        send(test_pid, {:leave_scope_called, result})
        {result, env}
      end

      env = Env.with_leave_scope(Env.new(), leave_scope)
      cancelled = %Cancelled{reason: :test_reason}

      {result, _final_env} = ISentinel.run(cancelled, env)

      assert_received {:leave_scope_called, ^cancelled}
      assert %Cancelled{reason: :test_reason} = result
    end

    test "leave_scope chain is invoked in order" do
      test_pid = self()

      # Inner leave_scope
      inner_leave_scope = fn result, env ->
        send(test_pid, {:inner, result})
        {result, env}
      end

      # Outer leave_scope that chains to inner
      outer_leave_scope = fn result, env ->
        send(test_pid, {:outer, result})
        inner_leave_scope.(result, env)
      end

      env = Env.with_leave_scope(Env.new(), outer_leave_scope)
      cancelled = %Cancelled{reason: :chain_test}

      ISentinel.run(cancelled, env)

      assert_received {:outer, %Cancelled{reason: :chain_test}}
      assert_received {:inner, %Cancelled{reason: :chain_test}}
    end
  end

  describe "Comp.cancel/3" do
    test "creates Cancelled and invokes leave_scope" do
      # Build a computation that yields
      comp =
        Yield.yield(:waiting)
        |> Yield.with_handler()

      {%ExternalSuspend{} = suspend, env} = Comp.run(comp)
      assert suspend.value == :waiting

      # The env has leave_scope set up from the Yield handler scope
      # When we cancel, it should propagate through

      # Cancel it
      {result, _final_env} = Comp.cancel(suspend, env, :user_cancelled)

      assert %Cancelled{reason: :user_cancelled} = result
    end

    test "invokes scoped effect cleanup on cancel" do
      test_pid = self()

      # Create a computation with scoped state that we can observe cleanup on
      comp =
        Yield.yield(:waiting)
        |> Comp.scoped(fn env ->
          # Set up some state
          modified_env = Env.put_state(env, :cleanup_test, :active)

          # leave_scope that reports cleanup
          finally_k = fn result, e ->
            send(test_pid, {:cleanup_called, result, Env.get_state(e, :cleanup_test)})
            {result, %{e | state: Map.delete(e.state, :cleanup_test)}}
          end

          {modified_env, finally_k}
        end)
        |> Yield.with_handler()

      {%ExternalSuspend{} = suspend, env} = Comp.run(comp)

      # Cancel - should trigger cleanup
      {result, _final_env} = Comp.cancel(suspend, env, :abort)

      assert %Cancelled{reason: :abort} = result
      assert_received {:cleanup_called, %Cancelled{reason: :abort}, :active}
    end

    test "nested scopes all get cleanup on cancel" do
      test_pid = self()

      # Inner scope
      inner =
        Yield.yield(:waiting)
        |> Comp.scoped(fn env ->
          finally_k = fn result, e ->
            send(test_pid, {:inner_cleanup, result})
            {result, e}
          end

          {env, finally_k}
        end)

      # Outer scope
      comp =
        inner
        |> Comp.scoped(fn env ->
          finally_k = fn result, e ->
            send(test_pid, {:outer_cleanup, result})
            {result, e}
          end

          {env, finally_k}
        end)
        |> Yield.with_handler()

      {%ExternalSuspend{} = suspend, env} = Comp.run(comp)

      # Cancel - both scopes should clean up
      {result, _final_env} = Comp.cancel(suspend, env, :shutdown)

      assert %Cancelled{reason: :shutdown} = result

      # Inner cleans up first (innermost leave_scope runs first in chain)
      assert_received {:inner_cleanup, %Cancelled{reason: :shutdown}}
      assert_received {:outer_cleanup, %Cancelled{reason: :shutdown}}
    end

    test "State handler cleanup on cancel" do
      # Real-world test: State handler should restore previous state on cancel
      comp =
        Comp.bind(State.put(42), fn _ ->
          Yield.yield(:waiting)
        end)
        |> State.with_handler(0)
        |> Yield.with_handler()

      {%ExternalSuspend{} = suspend, env} = Comp.run(comp)

      # State was modified to 42 before yielding
      # When we cancel, State's scoped cleanup should run

      {result, final_env} = Comp.cancel(suspend, env, :cancelled)

      assert %Cancelled{reason: :cancelled} = result

      # State handler should have cleaned up its state key
      # (The scoped state is removed when scope exits)
      state_key = {State, State}
      assert Env.get_state(final_env, state_key) == nil
    end
  end
end
