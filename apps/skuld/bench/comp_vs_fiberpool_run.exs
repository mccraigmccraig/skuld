# Comp.run overhead benchmark
#
# Run with: mix run bench/comp_vs_fiberpool_run.exs
#
# Measures the overhead of Comp.run's fiber-scheduling fast-path
# (drain_pending) and the cost of installing FiberPool.with_handler
# for computations that don't use fibers.

alias Skuld.Comp
alias Skuld.Effects.State, as: SkuldState
alias Skuld.Effects.FiberPool

defmodule CompVsFiberPoolBench do
  # ============================================================
  # Test computations
  # ============================================================

  # Simple State get/put loop — the core benchmark from skuld_benchmark.exs
  defp state_loop(target) do
    SkuldState.get()
    |> Comp.bind(fn n ->
      if n >= target do
        Comp.pure(n)
      else
        SkuldState.put(n + 1)
        |> Comp.bind(fn _ ->
          state_loop(target)
        end)
      end
    end)
  end

  # Trivial computation — measures pure run overhead
  defp trivial do
    Comp.pure(42)
  end

  # ============================================================
  # Runners
  # ============================================================

  def run_comp(computation) do
    Comp.run!(computation)
  end

  def run_fiberpool_with_handler(computation) do
    computation
    |> FiberPool.with_handler()
    |> Comp.run!()
  end

  # ============================================================
  # Benchmark
  # ============================================================

  def run do
    IO.puts("Comp.run Overhead Benchmark")
    IO.puts("===========================")
    IO.puts("")
    IO.puts("Measuring overhead of Comp.run's drain_pending fast-path")
    IO.puts("and FiberPool.with_handler on computations that don't use fibers.")
    IO.puts("")

    iterations = 7

    # --- Trivial computation ---
    IO.puts("1. Trivial computation (Comp.pure(42))")
    IO.puts("---------------------------------------")

    trivial_comp = trivial()
    trivial_with_state = trivial_comp |> SkuldState.with_handler(0)

    comp_trivial =
      median_time(iterations, fn -> :timer.tc(fn -> run_comp(trivial_with_state) end) end)

    fp_handler_trivial =
      median_time(iterations, fn ->
        :timer.tc(fn ->
          run_fiberpool_with_handler(trivial_comp |> SkuldState.with_handler(0))
        end)
      end)

    IO.puts("  Comp.run!:              #{format_time(comp_trivial)}")
    IO.puts("  Comp.run! + FP.handler: #{format_time(fp_handler_trivial)}")

    IO.puts(
      "  FP+h/Comp ratio:        #{Float.round(fp_handler_trivial / max(comp_trivial, 1), 2)}x"
    )

    IO.puts("")

    # --- State loop benchmarks at various sizes ---
    targets = [100, 500, 1_000, 5_000, 10_000]

    IO.puts("2. State get/put loop")
    IO.puts("---------------------")
    IO.puts("")

    header =
      String.pad_trailing("Target", 10) <>
        String.pad_trailing("Comp.run", 14) <>
        String.pad_trailing("FP+handler", 14) <>
        String.pad_trailing("FP+h/Comp", 10)

    IO.puts(header)
    IO.puts(String.duplicate("-", 48))

    for target <- targets do
      loop = state_loop(target)
      comp_wrapped = loop |> SkuldState.with_handler(0)
      fp_handler_wrapped = loop |> FiberPool.with_handler() |> SkuldState.with_handler(0)

      comp_time = median_time(iterations, fn -> :timer.tc(fn -> run_comp(comp_wrapped) end) end)

      fp_handler_time =
        median_time(iterations, fn ->
          :timer.tc(fn -> run_fiberpool_with_handler(fp_handler_wrapped) end)
        end)

      handler_ratio = Float.round(fp_handler_time / max(comp_time, 1), 2)

      IO.puts(
        String.pad_trailing("#{target}", 10) <>
          String.pad_trailing(format_time(comp_time), 14) <>
          String.pad_trailing(format_time(fp_handler_time), 14) <>
          String.pad_trailing("#{handler_ratio}x", 10)
      )
    end

    IO.puts("")
    IO.puts("Legend:")
    IO.puts("  Comp.run   — Comp.run! with no fiber handler (baseline)")
    IO.puts("  FP+handler — Comp.run! with FiberPool.with_handler installed")
    IO.puts("  FP+h/Comp  — Ratio (< 1.05 = negligible overhead)")
  end

  defp median_time(iterations, fun) do
    times =
      for _ <- 1..iterations do
        {time, _} = fun.()
        time
      end
      |> Enum.sort()

    Enum.at(times, div(iterations, 2))
  end

  defp format_time(microseconds) when microseconds < 1_000, do: "#{microseconds} µs"

  defp format_time(microseconds) when microseconds < 1_000_000 do
    "#{Float.round(microseconds / 1_000, 2)} ms"
  end

  defp format_time(microseconds), do: "#{Float.round(microseconds / 1_000_000, 2)} s"
end

CompVsFiberPoolBench.run()
