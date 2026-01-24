# Investigation: Stacktraces for Elixir raise/throw in Skuld computations
#
# Run with: mix run test/skuld/debugging/stacktrace_investigation.exs
#
# This script examines what stacktraces look like when errors occur
# in various places within Skuld computations.

defmodule StacktraceInvestigation do
  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Reader
  alias Skuld.Effects.State
  alias Skuld.Effects.Throw

  # A custom effect for testing handler errors
  defmodule RaisingEffect do
    alias Skuld.Comp

    defstruct [:should_raise]

    def maybe_raise(should_raise) do
      Comp.effect(__MODULE__, %__MODULE__{should_raise: should_raise})
    end

    def with_handler(computation) do
      Comp.with_handler(computation, __MODULE__, fn
        %__MODULE__{should_raise: true}, _env, _k ->
          raise "Error inside effect handler"

        %__MODULE__{should_raise: false}, env, k ->
          k.(:ok, env)
      end)
    end
  end

  def separator(title) do
    IO.puts("\n")
    IO.puts(String.duplicate("=", 80))
    IO.puts("  #{title}")
    IO.puts(String.duplicate("=", 80))
    IO.puts("")
  end

  def run_and_capture(name, fun) do
    IO.puts("--- #{name} ---\n")

    try do
      result = fun.()
      IO.puts("Result: #{inspect(result)}")
    rescue
      e ->
        IO.puts("Exception: #{inspect(e)}")
        IO.puts("\nStacktrace:")

        __STACKTRACE__
        |> Exception.format_stacktrace()
        |> IO.puts()
    catch
      kind, value ->
        IO.puts("Caught #{kind}: #{inspect(value)}")
        IO.puts("\nStacktrace:")

        __STACKTRACE__
        |> Exception.format_stacktrace()
        |> IO.puts()
    end

    IO.puts("")
  end

  # ============================================================================
  # Scenario 1: raise in pure computation (no effects, just return)
  # ============================================================================
  def scenario_1_raise_in_pure do
    computation =
      comp do
        x = 42
        _ = raise "Pure computation error with x=#{x}"
        x
      end

    computation
    |> Throw.with_handler()
    |> Comp.run!()
  end

  # ============================================================================
  # Scenario 2: raise after reading from Reader effect
  # ============================================================================
  def scenario_2_raise_after_effect do
    computation =
      comp do
        x <- Reader.ask()
        _ = raise "Error after Reader.ask, x=#{x}"
        x * 2
      end

    computation
    |> Reader.with_handler(42)
    |> Throw.with_handler()
    |> Comp.run!()
  end

  # ============================================================================
  # Scenario 3: raise inside effect handler
  # ============================================================================
  def scenario_3_raise_in_handler do
    computation =
      comp do
        _ <- RaisingEffect.maybe_raise(true)
        :should_not_reach
      end

    computation
    |> RaisingEffect.with_handler()
    |> Throw.with_handler()
    |> Comp.run!()
  end

  # ============================================================================
  # Scenario 4: raise in continuation (after effect returns)
  # ============================================================================
  def scenario_4_raise_in_continuation do
    computation =
      comp do
        x <- State.get()
        # This is the continuation - code that runs after the effect
        _ =
          if x < 0 do
            raise "Negative value in continuation: #{x}"
          end

        x * 2
      end

    computation
    |> State.with_handler(-5)
    |> Throw.with_handler()
    |> Comp.run!()
  end

  # ============================================================================
  # Scenario 5: raise in nested function called from computation
  # ============================================================================
  def scenario_5_raise_in_nested_function do
    computation =
      comp do
        x <- Reader.ask()
        result = process_value(x)
        result
      end

    computation
    |> Reader.with_handler(-10)
    |> Throw.with_handler()
    |> Comp.run!()
  end

  defp process_value(x) when x < 0 do
    validate_positive(x)
  end

  defp process_value(x), do: x * 2

  defp validate_positive(x) do
    raise ArgumentError, "Expected positive value, got: #{x}"
  end

  # ============================================================================
  # Scenario 6: Elixir throw (not Skuld Throw)
  # ============================================================================
  def scenario_6_elixir_throw do
    computation =
      comp do
        x <- Reader.ask()
        _ = throw({:early_exit, x})
        x * 2
      end

    computation
    |> Reader.with_handler(42)
    |> Throw.with_handler()
    |> Comp.run!()
  end

  # ============================================================================
  # Scenario 7: raise in deeply nested comp blocks
  # ============================================================================
  def scenario_7_nested_comp_blocks do
    inner =
      comp do
        y <- State.get()
        _ = raise "Error in inner comp, y=#{y}"
        y
      end

    outer =
      comp do
        x <- Reader.ask()
        result <- inner
        x + result
      end

    outer
    |> Reader.with_handler(10)
    |> State.with_handler(20)
    |> Throw.with_handler()
    |> Comp.run!()
  end

  # ============================================================================
  # Scenario 8: raise with multiple effects in scope
  # ============================================================================
  def scenario_8_multiple_effects do
    computation =
      comp do
        a <- Reader.ask()
        b <- State.get()
        _ <- State.put(b + 1)
        c <- State.get()

        _ =
          if a + c > 100 do
            raise "Sum too large: a=#{a}, c=#{c}"
          end

        a + c
      end

    computation
    |> Reader.with_handler(50)
    |> State.with_handler(60)
    |> Throw.with_handler()
    |> Comp.run!()
  end

  # ============================================================================
  # Main
  # ============================================================================
  def run do
    separator("SCENARIO 1: raise in pure computation")
    run_and_capture("Pure comp raise", &scenario_1_raise_in_pure/0)

    separator("SCENARIO 2: raise after Reader.ask effect")
    run_and_capture("Raise after effect", &scenario_2_raise_after_effect/0)

    separator("SCENARIO 3: raise inside effect handler")
    run_and_capture("Raise in handler", &scenario_3_raise_in_handler/0)

    separator("SCENARIO 4: raise in continuation")
    run_and_capture("Raise in continuation", &scenario_4_raise_in_continuation/0)

    separator("SCENARIO 5: raise in nested function")
    run_and_capture("Raise in nested fn", &scenario_5_raise_in_nested_function/0)

    separator("SCENARIO 6: Elixir throw (not Skuld Throw)")
    run_and_capture("Elixir throw", &scenario_6_elixir_throw/0)

    separator("SCENARIO 7: raise in nested comp blocks")
    run_and_capture("Nested comp raise", &scenario_7_nested_comp_blocks/0)

    separator("SCENARIO 8: raise with multiple effects")
    run_and_capture("Multiple effects raise", &scenario_8_multiple_effects/0)

    separator("INVESTIGATION COMPLETE")
    IO.puts("Review the stacktraces above to assess debugging experience.")
  end
end

StacktraceInvestigation.run()
