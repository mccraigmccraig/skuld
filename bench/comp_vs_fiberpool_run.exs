# Comp.run vs FiberPool.run Benchmark
#
# Run with: mix run bench/comp_vs_fiberpool_run.exs
#
# Compares the overhead of FiberPool.run (with fiber scheduling fast-path)
# against Comp.run (simple execution) for computations that don't use fibers.
#
# This measures whether FiberPool.run's extra work (PendingWork extraction,
# empty list check) is cheap enough to justify replacing Comp.run.

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

  def run_fiberpool(computation) do
    FiberPool.run!(computation)
  end

  def run_fiberpool_with_handler(computation) do
    computation
    |> FiberPool.with_handler()
    |> FiberPool.run!()
  end

  # ============================================================
  # Benchmark
  # ============================================================

  def run do
    IO.puts("Comp.run vs FiberPool.run Benchmark")
    IO.puts("====================================")
    IO.puts("")
    IO.puts("Measuring overhead of FiberPool.run's fiber-scheduling fast-path")
    IO.puts("on computations that don't use fibers.")
    IO.puts("")

    iterations = 7

    # --- Trivial computation ---
    IO.puts("1. Trivial computation (Comp.pure(42))")
    IO.puts("---------------------------------------")

    trivial_comp = trivial()
    trivial_with_state = trivial() |> SkuldState.with_handler(0)

    comp_trivial =
      median_time(iterations, fn -> :timer.tc(fn -> run_comp(trivial_with_state) end) end)

    fp_trivial =
      median_time(iterations, fn -> :timer.tc(fn -> run_fiberpool(trivial_with_state) end) end)

    fp_handler_trivial =
      median_time(iterations, fn ->
        :timer.tc(fn ->
          run_fiberpool_with_handler(trivial_comp |> SkuldState.with_handler(0))
        end)
      end)

    IO.puts("  Comp.run!:                    #{format_time(comp_trivial)}")
    IO.puts("  FiberPool.run!:               #{format_time(fp_trivial)}")
    IO.puts("  FiberPool.run! + with_handler: #{format_time(fp_handler_trivial)}")

    IO.puts(
      "  FP/Comp ratio:                #{Float.round(fp_trivial / max(comp_trivial, 1), 2)}x"
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
        String.pad_trailing("FP.run", 14) <>
        String.pad_trailing("FP+handler", 14) <>
        String.pad_trailing("FP/Comp", 10) <>
        String.pad_trailing("FP+h/Comp", 10)

    IO.puts(header)
    IO.puts(String.duplicate("-", 72))

    for target <- targets do
      loop = state_loop(target)
      comp_wrapped = loop |> SkuldState.with_handler(0)
      fp_wrapped = loop |> SkuldState.with_handler(0)
      fp_handler_wrapped = loop |> FiberPool.with_handler() |> SkuldState.with_handler(0)

      comp_time = median_time(iterations, fn -> :timer.tc(fn -> run_comp(comp_wrapped) end) end)
      fp_time = median_time(iterations, fn -> :timer.tc(fn -> run_fiberpool(fp_wrapped) end) end)

      fp_handler_time =
        median_time(iterations, fn ->
          :timer.tc(fn -> run_fiberpool_with_handler(fp_handler_wrapped) end)
        end)

      ratio = Float.round(fp_time / max(comp_time, 1), 2)
      handler_ratio = Float.round(fp_handler_time / max(comp_time, 1), 2)

      IO.puts(
        String.pad_trailing("#{target}", 10) <>
          String.pad_trailing(format_time(comp_time), 14) <>
          String.pad_trailing(format_time(fp_time), 14) <>
          String.pad_trailing(format_time(fp_handler_time), 14) <>
          String.pad_trailing("#{ratio}x", 10) <>
          String.pad_trailing("#{handler_ratio}x", 10)
      )
    end

    IO.puts("")
    IO.puts("Legend:")
    IO.puts("  Comp.run   — Current simple Comp.run! (baseline)")
    IO.puts("  FP.run     — FiberPool.run! without with_handler (scheduling overhead only)")
    IO.puts("  FP+handler — FiberPool.run! with with_handler (full fiber support installed)")
    IO.puts("  FP/Comp    — Ratio of FP.run to Comp.run (< 1.05 = negligible overhead)")
    IO.puts("  FP+h/Comp  — Ratio of FP+handler to Comp.run")
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
