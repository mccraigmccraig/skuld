defmodule Skuld.Comp.CompBlockTest do
  use ExUnit.Case, async: true

  import Skuld.Comp.CompBlock

  alias Skuld.Comp
  alias Skuld.Effects.State
  alias Skuld.Effects.Reader
  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield

  describe "comp macro" do
    test "single return" do
      computation =
        comp do
          return(42)
        end

      assert Comp.run!(computation) == 42
    end

    test "pure binding with =" do
      computation =
        comp do
          x = 10
          y = x + 5
          return(y)
        end

      assert Comp.run!(computation) == 15
    end

    test "effect binding with <-" do
      computation =
        comp do
          x <- State.get()
          return(x + 1)
        end
        |> State.with_handler(10)

      assert Comp.run!(computation) == 11
    end

    test "multiple effect bindings" do
      computation =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          y <- State.get()
          return({x, y})
        end
        |> State.with_handler(5)

      assert Comp.run!(computation) == {5, 6}
    end

    test "mixed pure and effect bindings" do
      computation =
        comp do
          x <- State.get()
          y = x * 2
          _ <- State.put(y)
          z <- State.get()
          return({x, y, z})
        end
        |> State.with_handler(3)

      assert Comp.run!(computation) == {3, 6, 6}
    end

    test "ignoring result with _" do
      computation =
        comp do
          _ <- State.put(100)
          x <- State.get()
          return(x)
        end
        |> State.with_handler(0)

      assert Comp.run!(computation) == 100
    end

    test "with Reader effect" do
      computation =
        comp do
          ctx <- Reader.ask()
          return(ctx.value * 2)
        end
        |> Reader.with_handler(%{value: 21})

      assert Comp.run!(computation) == 42
    end

    test "combining multiple effects" do
      computation =
        comp do
          ctx <- Reader.ask()
          x <- State.get()
          _ <- State.put(x + ctx.increment)
          y <- State.get()
          return({x, y})
        end
        |> Reader.with_handler(%{increment: 10})
        |> State.with_handler(5)

      assert Comp.run!(computation) == {5, 15}
    end

    test "nested computations" do
      inner =
        comp do
          x <- State.get()
          return(x * 2)
        end

      outer =
        comp do
          _ <- State.put(10)
          result <- inner
          return(result + 1)
        end
        |> State.with_handler(0)

      assert Comp.run!(outer) == 21
    end

    test "pattern matching in binding" do
      computation =
        comp do
          {a, b} <- Comp.pure({1, 2})
          return(a + b)
        end

      assert Comp.run!(computation) == 3
    end
  end

  describe "auto-lifting ergonomics" do
    alias Skuld.Effects.Writer

    test "final expression without return is auto-lifted" do
      # No longer need return() for final expression
      computation =
        comp do
          x <- State.get()
          x + 1
        end
        |> State.with_handler(10)

      assert Comp.run!(computation) == 11
    end

    test "if without else is auto-lifted (nil becomes pure(nil))" do
      computation =
        comp do
          x <- State.get()
          _ <- if x > 5, do: Writer.tell(:big)
          return(:done)
        end
        |> State.with_handler(10)
        |> Writer.with_handler([], output: fn r, log -> {r, log} end)

      assert Comp.run!(computation) == {:done, [:big]}
    end

    test "if without else when condition is false" do
      computation =
        comp do
          x <- State.get()
          _ <- if x > 5, do: Writer.tell(:big)
          return(:done)
        end
        |> State.with_handler(3)
        |> Writer.with_handler([], output: fn r, log -> {r, log} end)

      # No write happens when x <= 5
      assert Comp.run!(computation) == {:done, []}
    end

    test "plain value in comp block is auto-lifted" do
      computation =
        comp do
          42
        end

      assert Comp.run!(computation) == 42
    end

    test "complex expression as final value" do
      computation =
        comp do
          x <- Reader.ask()
          y <- State.get()
          %{sum: x + y, product: x * y}
        end
        |> Reader.with_handler(3)
        |> State.with_handler(4)

      assert Comp.run!(computation) == %{sum: 7, product: 12}
    end
  end

  describe "defcomp macro" do
    defcomp simple_get do
      x <- State.get()
      return(x)
    end

    defcomp increment_and_get do
      x <- State.get()
      _ <- State.put(x + 1)
      y <- State.get()
      return({x, y})
    end

    defcomp with_arg(multiplier) do
      x <- State.get()
      return(x * multiplier)
    end

    defcomp with_multiple_args(a, b) do
      x <- State.get()
      return(x + a + b)
    end

    test "defcomp with no args" do
      assert Comp.run!(simple_get() |> State.with_handler(42)) == 42
    end

    test "defcomp with effects" do
      assert Comp.run!(increment_and_get() |> State.with_handler(10)) == {10, 11}
    end

    test "defcomp with single arg" do
      assert Comp.run!(with_arg(3) |> State.with_handler(5)) == 15
    end

    test "defcomp with multiple args" do
      assert Comp.run!(with_multiple_args(5, 3) |> State.with_handler(10)) == 18
    end
  end

  describe "defcompp macro" do
    # We can't directly test private functions, but we can test them indirectly

    defcompp private_double do
      x <- State.get()
      return(x * 2)
    end

    defcomp uses_private do
      x <- private_double()
      _ <- State.put(x)
      return(x)
    end

    test "defcompp defines private function usable internally" do
      assert Comp.run!(uses_private() |> State.with_handler(21)) == 42
    end
  end

  describe "use Skuld.Syntax" do
    defmodule UseSyntaxExample do
      use Skuld.Syntax

      alias Skuld.Effects.State

      defcomp get_doubled do
        x <- State.get()
        return(x * 2)
      end
    end

    test "use Skuld.Syntax imports macros" do
      computation = UseSyntaxExample.get_doubled() |> State.with_handler(10)
      assert Comp.run!(computation) == 20
    end
  end

  describe "edge cases" do
    test "empty block with just return" do
      computation =
        comp do
          return(:ok)
        end

      assert Comp.run!(computation) == :ok
    end

    test "computation as last expression without return" do
      computation =
        comp do
          x <- Comp.pure(10)
          Comp.pure(x + 1)
        end

      assert Comp.run!(computation) == 11
    end

    test "complex pattern in binding" do
      computation =
        comp do
          %{a: a, b: b} <- Comp.pure(%{a: 1, b: 2, c: 3})
          return(a + b)
        end

      assert Comp.run!(computation) == 3
    end
  end

  describe "catch clause" do
    test "catches thrown error" do
      computation =
        comp do
          _ <- Throw.throw(:my_error)
          return(:never_reached)
        catch
          {Throw, :my_error} -> return(:caught)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == :caught
    end

    test "passes through normal completion" do
      computation =
        comp do
          return(42)
        catch
          {Throw, _} -> return(:caught)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == 42
    end

    test "pattern matches on error value" do
      computation =
        comp do
          _ <- Throw.throw({:error, :not_found})
          return(:never_reached)
        catch
          {Throw, {:error, :not_found}} -> return(:not_found_handled)
          {Throw, {:error, reason}} -> return({:other_error, reason})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == :not_found_handled
    end

    test "unhandled error is re-thrown" do
      computation =
        comp do
          _ <- Throw.throw(:unhandled)
          return(:never_reached)
        catch
          {Throw, :specific_error} -> return(:handled)
        end
        |> Throw.with_handler()

      {result, _env} = Comp.run(computation)
      assert %Comp.Throw{error: :unhandled} = result
    end

    test "catch-all clause handles any error" do
      computation =
        comp do
          _ <- Throw.throw(:any_error)
          return(:never_reached)
        catch
          {Throw, err} -> return({:caught, err})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught, :any_error}
    end

    test "catch with state effects preserves state changes before throw" do
      computation =
        comp do
          _ <- State.put(100)
          _ <- Throw.throw(:error)
          return(:never_reached)
        catch
          {Throw, :error} ->
            x <- State.get()
            return({:recovered, x})
        end
        |> State.with_handler(0)
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:recovered, 100}
    end

    test "catch handler can use effects" do
      computation =
        comp do
          _ <- Throw.throw(:error)
          return(:never_reached)
        catch
          {Throw, :error} ->
            ctx <- Reader.ask()
            return({:recovered, ctx.default})
        end
        |> Reader.with_handler(%{default: :fallback})
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:recovered, :fallback}
    end

    test "catch handler returning {:ok, value} is not incorrectly unwrapped" do
      computation =
        comp do
          _ <- Throw.throw(:error)
          return(:never_reached)
        catch
          {Throw, :error} -> return({:ok, :recovered})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:ok, :recovered}
    end

    test "nested catch - inner catches first" do
      inner =
        comp do
          _ <- Throw.throw(:inner_error)
          return(:never)
        catch
          {Throw, :inner_error} -> return(:inner_caught)
        end

      outer =
        comp do
          result <- inner
          return({:outer_got, result})
        catch
          {Throw, _} -> return(:outer_caught)
        end
        |> Throw.with_handler()

      assert Comp.run!(outer) == {:outer_got, :inner_caught}
    end

    test "outer catch handles errors from inner when not caught" do
      inner =
        comp do
          _ <- Throw.throw(:uncaught_inner)
          return(:never)
        catch
          {Throw, :different_error} -> return(:inner_caught)
        end

      outer =
        comp do
          result <- inner
          return({:outer_got, result})
        catch
          {Throw, :uncaught_inner} -> return(:outer_caught_inner_error)
        end
        |> Throw.with_handler()

      assert Comp.run!(outer) == :outer_caught_inner_error
    end
  end

  describe "defcomp with catch" do
    defcomp safe_divide(a, b) do
      _ <- if b == 0, do: Throw.throw(:divide_by_zero), else: Comp.pure(:ok)
      return(div(a, b))
    catch
      {Throw, :divide_by_zero} -> return(:infinity)
    end

    defcomp fetch_with_default(key, default) do
      _ <- Throw.throw({:not_found, key})
      return(:never)
    catch
      {Throw, {:not_found, _}} -> return(default)
    end

    test "defcomp with catch handles error" do
      assert Comp.run!(safe_divide(10, 0) |> Throw.with_handler()) == :infinity
    end

    test "defcomp with catch passes through success" do
      assert Comp.run!(safe_divide(10, 2) |> Throw.with_handler()) == 5
    end

    test "defcomp with catch and args" do
      computation = fetch_with_default(:missing, :default_value) |> Throw.with_handler()
      assert Comp.run!(computation) == :default_value
    end
  end

  describe "defcompp with catch" do
    defcompp private_risky do
      _ <- Throw.throw(:private_error)
      return(:never)
    catch
      {Throw, :private_error} -> return(:privately_handled)
    end

    defcomp uses_private_risky do
      result <- private_risky()
      return({:got, result})
    end

    test "defcompp with catch works" do
      assert Comp.run!(uses_private_risky() |> Throw.with_handler()) ==
               {:got, :privately_handled}
    end
  end

  describe "else clause" do
    test "handles pattern match failure in <-" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :not_found})
          return(x)
        else
          {:error, reason} -> return({:failed, reason})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:failed, :not_found}
    end

    test "passes through successful match" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:ok, 42})
          return(x)
        else
          {:error, _} -> return(:failed)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == 42
    end

    test "handles multiple patterns in else" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :specific})
          return(x)
        else
          {:error, :specific} -> return(:specific_handled)
          {:error, _} -> return(:generic_error)
          other -> return({:unexpected, other})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == :specific_handled
    end

    test "unhandled match failure propagates as MatchFailed" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :unhandled})
          return(x)
        else
          {:error, :specific} -> return(:handled)
        end
        |> Throw.with_handler()

      {result, _} = Comp.run(computation)
      assert %Comp.Throw{error: %Comp.MatchFailed{value: {:error, :unhandled}}} = result
    end

    test "else with catch-all handles any mismatch" do
      computation =
        comp do
          {:ok, x} <- Comp.pure(:something_else)
          return(x)
        else
          other -> return({:caught, other})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught, :something_else}
    end

    test "simple patterns don't trigger else" do
      # Simple variable patterns always match, so else is never called
      computation =
        comp do
          x <- Comp.pure(42)
          return(x * 2)
        else
          _ -> return(:should_not_reach)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == 84
    end

    test "handles pattern match failure in = binding" do
      computation =
        comp do
          x <- Comp.pure(10)
          {:ok, y} = {:error, :oops}
          return(x + y)
        else
          {:error, reason} -> return({:assignment_failed, reason})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:assignment_failed, :oops}
    end

    test "else handler can use effects" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :failed})
          return(x)
        else
          {:error, _} ->
            s <- State.get()
            return({:recovered_with_state, s})
        end
        |> State.with_handler(100)
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:recovered_with_state, 100}
    end

    test "multiple <- bindings with else" do
      computation =
        comp do
          {:ok, a} <- Comp.pure({:ok, 1})
          {:ok, b} <- Comp.pure({:ok, 2})
          {:ok, c} <- Comp.pure({:error, :third_failed})
          return(a + b + c)
        else
          {:error, reason} -> return({:failed_at, reason})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:failed_at, :third_failed}
    end
  end

  describe "compile-time validation" do
    test "bare expression in non-final position is a compile error" do
      # comp blocks should only allow:
      # - `pattern <- computation` (effectful bind)
      # - `pattern = expression` (pure bind)
      # - final expression (auto-lifted to pure)
      #
      # Bare expressions like `IO.puts("foo")` in non-final position should fail
      assert_raise CompileError, ~r/bare expression/, fn ->
        Code.compile_string("""
        import Skuld.Comp.CompBlock
        comp do
          IO.puts("side effect")
          :final_value
        end
        """)
      end
    end

    test "multiple bare expressions are compile errors" do
      assert_raise CompileError, ~r/bare expression/, fn ->
        Code.compile_string("""
        import Skuld.Comp.CompBlock
        comp do
          IO.puts("first")
          IO.puts("second")
          :final_value
        end
        """)
      end
    end

    test "bare expression after binding is a compile error" do
      assert_raise CompileError, ~r/bare expression/, fn ->
        Code.compile_string("""
        import Skuld.Comp.CompBlock
        alias Skuld.Comp
        comp do
          x <- Comp.pure(1)
          IO.puts("side effect")
          x + 1
        end
        """)
      end
    end

    test "function call returning computation in non-final position needs binding" do
      # This should fail because `some_effect()` is a bare expression
      assert_raise CompileError, ~r/bare expression/, fn ->
        Code.compile_string("""
        import Skuld.Comp.CompBlock
        alias Skuld.Comp
        defmodule TempModule do
          def some_effect, do: Comp.pure(:ok)
        end
        comp do
          TempModule.some_effect()
          :done
        end
        """)
      end
    end
  end

  describe "else with catch" do
    test "else inside catch - throws from else are caught" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :match_fail})
          return(x)
        else
          {:error, :match_fail} ->
            _ <- Throw.throw(:else_threw)
            return(:never)
        catch
          {Throw, :else_threw} -> return(:catch_got_else_throw)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == :catch_got_else_throw
    end

    test "else inside catch - throws from body pass through else to catch" do
      computation =
        comp do
          _ <- Throw.throw(:body_threw)
          {:ok, x} <- Comp.pure({:ok, 42})
          return(x)
        else
          {:error, _} -> return(:else_handled)
        catch
          {Throw, :body_threw} -> return(:catch_got_body_throw)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == :catch_got_body_throw
    end

    test "else handles match failure, catch handles throw" do
      computation =
        comp do
          {:ok, x} <- Comp.pure({:error, :no_match})
          return(x)
        else
          {:error, :no_match} -> return(:else_handled_match)
        catch
          {Throw, :some_error} -> return(:catch_handled_throw)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == :else_handled_match
    end

    test "ordering validation - else must come before catch" do
      # This should raise a CompileError at compile time
      # We can't easily test compile errors, but we document the behavior
      assert_raise CompileError, ~r/else.*must come before.*catch/, fn ->
        Code.compile_string("""
        import Skuld.Comp.CompBlock
        comp do
          return(:ok)
        catch
          {Throw, _} -> return(:caught)
        else
          _ -> return(:else)
        end
        """)
      end
    end
  end

  describe "defcomp with else" do
    defcomp safe_unwrap(result) do
      {:ok, value} <- Comp.pure(result)
      return(value)
    else
      {:error, reason} -> return({:failed, reason})
      other -> return({:unexpected, other})
    end

    test "defcomp with else handles match failure" do
      assert Comp.run!(safe_unwrap({:ok, 42}) |> Throw.with_handler()) == 42

      assert Comp.run!(safe_unwrap({:error, :oops}) |> Throw.with_handler()) ==
               {:failed, :oops}

      assert Comp.run!(safe_unwrap(:weird) |> Throw.with_handler()) ==
               {:unexpected, :weird}
    end
  end

  describe "defcomp with else and catch" do
    defcomp complex_handler(input) do
      {:ok, x} <- Comp.pure(input)
      _ <- if x < 0, do: Throw.throw(:negative), else: Comp.pure(:ok)
      return(x * 2)
    else
      {:error, reason} -> return({:match_failed, reason})
    catch
      {Throw, :negative} -> return(:was_negative)
    end

    test "defcomp with else and catch - match failure" do
      assert Comp.run!(complex_handler({:error, :bad}) |> Throw.with_handler()) ==
               {:match_failed, :bad}
    end

    test "defcomp with else and catch - throw" do
      assert Comp.run!(complex_handler({:ok, -5}) |> Throw.with_handler()) ==
               :was_negative
    end

    test "defcomp with else and catch - success" do
      assert Comp.run!(complex_handler({:ok, 10}) |> Throw.with_handler()) == 20
    end
  end

  describe "Elixir exception handling in comp blocks" do
    # Tests that Elixir exceptions (raise/throw/exit) are properly converted
    # to Skuld Throw effects, even when they occur in the first expression
    # of a comp block (before any computation context exists).

    alias Skuld.Comp.Throw, as: ThrowStruct

    defmodule Risky do
      def boom!, do: raise("boom!")
      def throw_it!, do: throw(:thrown_value)
      def exit_it!, do: exit(:shutdown)
    end

    test "single expression that raises is converted to Throw" do
      computation =
        comp do
          Risky.boom!()
        end

      {result, _env} = Comp.run(computation)
      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "boom!"} = error.payload
    end

    test "single expression that raises can be caught" do
      computation =
        comp do
          Risky.boom!()
        catch
          {Throw, %{kind: :error, payload: %RuntimeError{message: msg}}} -> return({:caught, msg})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught, "boom!"}
    end

    test "RHS of <- binding that raises is converted to Throw" do
      computation =
        comp do
          x <- Risky.boom!()
          return(x)
        end

      {result, _env} = Comp.run(computation)
      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "boom!"} = error.payload
    end

    test "RHS of <- binding that raises can be caught" do
      computation =
        comp do
          x <- Risky.boom!()
          return(x)
        catch
          {Throw, %{kind: :error, payload: %RuntimeError{message: msg}}} -> return({:caught, msg})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught, "boom!"}
    end

    test "discarded binding expression that raises is converted to Throw" do
      computation =
        comp do
          _ <- Risky.boom!()
          x <- State.get()
          return(x)
        end
        |> State.with_handler(42)

      {result, _env} = Comp.run(computation)
      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "boom!"} = error.payload
    end

    test "discarded binding expression that raises can be caught" do
      computation =
        comp do
          _ <- Risky.boom!()
          x <- State.get()
          return(x)
        catch
          {Throw, %{kind: :error, payload: %RuntimeError{message: msg}}} -> return({:caught, msg})
        end
        |> State.with_handler(42)
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught, "boom!"}
    end

    test "last expression that raises is converted to Throw" do
      computation =
        comp do
          x <- State.get()
          _ = x
          Risky.boom!()
        end
        |> State.with_handler(42)

      {result, _env} = Comp.run(computation)
      assert %ThrowStruct{error: error} = result
      assert error.kind == :error
      assert %RuntimeError{message: "boom!"} = error.payload
    end

    test "last expression that raises can be caught" do
      computation =
        comp do
          x <- State.get()
          _ = x
          Risky.boom!()
        catch
          {Throw, %{kind: :error, payload: %RuntimeError{message: msg}}} -> return({:caught, msg})
        end
        |> State.with_handler(42)
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught, "boom!"}
    end

    test "Elixir throw is converted to Throw with kind: :throw" do
      computation =
        comp do
          Risky.throw_it!()
        end

      {result, _env} = Comp.run(computation)
      assert %ThrowStruct{error: error} = result
      assert error.kind == :throw
      assert error.payload == :thrown_value
    end

    test "Elixir throw can be caught" do
      computation =
        comp do
          Risky.throw_it!()
        catch
          {Throw, %{kind: :throw, payload: value}} -> return({:caught_throw, value})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught_throw, :thrown_value}
    end

    test "exit is converted to Throw with kind: :exit" do
      computation =
        comp do
          Risky.exit_it!()
        end

      {result, _env} = Comp.run(computation)
      assert %ThrowStruct{error: error} = result
      assert error.kind == :exit
      assert error.payload == :shutdown
    end

    test "exit can be caught" do
      computation =
        comp do
          Risky.exit_it!()
        catch
          {Throw, %{kind: :exit, payload: reason}} -> return({:caught_exit, reason})
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == {:caught_exit, :shutdown}
    end

    test "exception after successful bindings is caught" do
      computation =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          y <- State.get()
          _ = y
          Risky.boom!()
        catch
          {Throw, %{kind: :error, payload: %RuntimeError{message: msg}}} ->
            final <- State.get()
            return({:caught, msg, final})
        end
        |> State.with_handler(10)
        |> Throw.with_handler()

      # State changes before the exception should be preserved
      assert Comp.run!(computation) == {:caught, "boom!", 11}
    end
  end

  describe "Yield interception via catch" do
    test "single Yield pattern intercepts yield" do
      computation =
        comp do
          x <- Yield.yield(:question)
          return({:got, x})
        catch
          {Yield, :question} -> return(42)
        end
        |> Yield.with_handler()

      # The yield is intercepted and returns 42 as resume input
      assert Comp.run!(computation) == {:got, 42}
    end

    test "multiple Yield patterns" do
      computation =
        comp do
          x <- Yield.yield(:first)
          y <- Yield.yield(:second)
          return({x, y})
        catch
          {Yield, :first} -> return(10)
          {Yield, :second} -> return(20)
        end
        |> Yield.with_handler()

      assert Comp.run!(computation) == {10, 20}
    end

    test "unhandled yields are re-yielded by default" do
      computation =
        comp do
          x <- Yield.yield(:handled)
          y <- Yield.yield(:not_handled)
          return({x, y})
        catch
          {Yield, :handled} -> return(10)
        end
        |> Yield.with_handler()

      # :not_handled is re-yielded, so we get a Suspend
      {result, _env} = Comp.run(computation)
      assert %Comp.Suspend{value: :not_handled} = result
    end

    test "Yield handler can use effects" do
      computation =
        comp do
          x <- Yield.yield(:need_state)
          return({:got, x})
        catch
          {Yield, :need_state} ->
            s <- State.get()
            return(s * 2)
        end
        |> State.with_handler(21)
        |> Yield.with_handler()

      assert Comp.run!(computation) == {:got, 42}
    end

    test "Yield handler that throws is caught by outer Throw catch" do
      computation =
        comp do
          x <- Yield.yield(:will_throw)
          return({:got, x})
        catch
          {Yield, :will_throw} ->
            _ <- Throw.throw(:yield_handler_threw)
            return(:never)

          {Throw, :yield_handler_threw} ->
            return(:caught_from_yield_handler)
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == :caught_from_yield_handler
    end

    test "mixed Throw and Yield in same catch block" do
      computation =
        comp do
          x <- Yield.yield(:get_value)
          _ <- if x < 0, do: Throw.throw(:negative), else: Comp.pure(:ok)
          return(x * 2)
        catch
          {Yield, :get_value} -> return(-5)
          {Throw, :negative} -> return(:was_negative)
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == :was_negative
    end

    test "mixed Throw and Yield - success path" do
      computation =
        comp do
          x <- Yield.yield(:get_value)
          _ <- if x < 0, do: Throw.throw(:negative), else: Comp.pure(:ok)
          return(x * 2)
        catch
          {Yield, :get_value} -> return(5)
          {Throw, :negative} -> return(:was_negative)
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == 10
    end

    test "Yield catch-all pattern" do
      computation =
        comp do
          x <- Yield.yield(:any_value)
          return({:got, x})
        catch
          {Yield, value} -> return({:responded_to, value})
        end
        |> Yield.with_handler()

      assert Comp.run!(computation) == {:got, {:responded_to, :any_value}}
    end

    test "re-yield to propagate to outer handler" do
      inner =
        comp do
          x <- Yield.yield(:inner_question)
          return({:inner_got, x})
        catch
          {Yield, :handled_locally} -> return(:local)
          {Yield, other} -> Yield.yield({:forwarded, other})
        end

      computation =
        comp do
          result <- inner
          return({:outer_got, result})
        end
        |> Yield.with_handler()

      {result, _env} = Comp.run(computation)
      assert %Comp.Suspend{value: {:forwarded, :inner_question}} = result
    end
  end

  describe "catch clause ordering - consecutive grouping" do
    test "consecutive same-module clauses are grouped into one handler" do
      # Throw, Throw -> one catch_error with both patterns
      computation =
        comp do
          x <- Throw.throw(:first)
          return({:got, x})
        catch
          {Throw, :first} -> return(:caught_first)
          {Throw, :second} -> return(:caught_second)
        end
        |> Throw.with_handler()

      assert Comp.run!(computation) == :caught_first
    end

    test "interleaved modules create separate interceptor layers" do
      # {Throw, :a}, {Yield, :b}, {Throw, :c} creates three layers:
      # catch_error(respond(catch_error(body, a_handler), b_handler), c_handler)

      # The Yield handler throws, which should be caught by the OUTER Throw handler
      computation =
        comp do
          x <- Yield.yield(:need_value)
          return({:got, x})
        catch
          # First Throw layer (inner)
          {Throw, :from_body} ->
            return(:caught_from_body)

          # Yield layer (middle)
          {Yield, :need_value} ->
            _ <- Throw.throw(:from_yield_handler)
            return(:never)

          # Second Throw layer (outer) - catches throws from Yield handler
          {Throw, :from_yield_handler} ->
            return(:caught_from_yield_handler)
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == :caught_from_yield_handler
    end

    test "Throw-first ordering: Throw catches before Yield responds" do
      # When Throw comes first, body throws are caught before Yield is checked
      computation =
        comp do
          _ <- Throw.throw(:early_error)
          x <- Yield.yield(:never_reached)
          return({:got, x})
        catch
          # Throw first (inner) - catches body throws
          {Throw, :early_error} -> return(:caught_early)
          # Yield second (outer) - never sees anything
          {Yield, :never_reached} -> return(:responded)
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == :caught_early
    end

    test "Yield-first ordering: Yield handler throw goes to outer Throw" do
      # When Yield comes first and its handler throws, outer Throw catches it
      computation =
        comp do
          x <- Yield.yield(:get_value)
          return({:got, x})
        catch
          # Yield first (inner)
          {Yield, :get_value} ->
            _ <- Throw.throw(:yield_threw)
            return(:never)

          # Throw second (outer) - catches throws from Yield handler
          {Throw, :yield_threw} ->
            return(:outer_caught)
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == :outer_caught
    end

    test "multiple alternating layers" do
      # Throw, Yield, Throw, Yield creates four layers
      # This tests that each module switch creates a new layer

      computation =
        comp do
          # This yield will be caught by first Yield layer
          x <- Yield.yield(:first_yield)
          return({:got, x})
        catch
          # Layer 1: Throw (inner)
          {Throw, :layer1} ->
            return(:from_layer1)

          # Layer 2: Yield
          {Yield, :first_yield} ->
            # This throw will be caught by layer 3, not layer 1
            _ <- Throw.throw(:from_layer2)
            return(:never)

          # Layer 3: Throw
          {Throw, :from_layer2} ->
            # This yield will be caught by layer 4
            Yield.yield(:from_layer3)

          # Layer 4: Yield (outer)
          {Yield, :from_layer3} ->
            return(:from_layer4)
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == :from_layer4
    end

    test "clause order determines which Throw layer catches" do
      # First: {Throw, :a} - inner
      # Then: {Yield, :x}
      # Then: {Throw, :b} - outer
      # A throw of :b from Yield handler should be caught by outer, not inner

      computation =
        comp do
          x <- Yield.yield(:trigger)
          return({:got, x})
        catch
          # Inner Throw - handles :a only
          {Throw, :a} ->
            return(:inner_caught_a)

          # Yield - throws :b
          {Yield, :trigger} ->
            _ <- Throw.throw(:b)
            return(:never)

          # Outer Throw - handles :b
          {Throw, :b} ->
            return(:outer_caught_b)
        end
        |> Yield.with_handler()
        |> Throw.with_handler()

      assert Comp.run!(computation) == :outer_caught_b
    end
  end
end
