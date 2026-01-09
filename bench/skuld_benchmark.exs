# Skuld Performance Benchmark
#
# Run with: mix run bench/skuld_benchmark.exs
#
# Compares Skuld against pure baselines and simple effect implementations:
#
# 1. Pure/Recurse  - Non-effectful baseline using recursion
# 2. Monad/Nested  - Simple state monad (no effects library)
# 3. Evf/Nested    - Flat evidence-passing, direct-style (no CPS)
# 4. Evf/CPS       - Flat evidence-passing with CPS (isolates CPS overhead)
# 5. Skuld/Nested  - Skuld with nested binds
# 6. Skuld/FxFL    - Skuld with FxFasterList iteration
# 7. Skuld/Yield   - Skuld with coroutine-style iteration

alias Skuld.Comp
alias Skuld.Effects.State, as: SkuldState
alias Skuld.Effects.FxFasterList, as: SkuldFxFasterList
alias Skuld.Effects.FxList, as: SkuldFxList
alias Skuld.Effects.Yield, as: SkuldYield

defmodule SkuldBenchmark do
  # ============================================================
  # Pure baselines - no effects, just computation
  # ============================================================

  def pure_reduce(target) do
    initial_state = %{counter: 0}

    final_state =
      Enum.reduce(1..target, initial_state, fn _i, state ->
        n = Map.get(state, :counter)

        if n >= target do
          state
        else
          Map.put(state, :counter, n + 1)
        end
      end)

    Map.get(final_state, :counter)
  end

  def pure_recurse(target) do
    initial_state = %{counter: 0}
    {result, _final_state} = pure_recurse_loop(target, initial_state)
    result
  end

  defp pure_recurse_loop(target, state) do
    n = Map.get(state, :counter)

    if n >= target do
      {n, state}
    else
      new_state = Map.put(state, :counter, n + 1)
      pure_recurse_loop(target, new_state)
    end
  end

  # ============================================================
  # Simple State Monad - baseline for effect overhead
  # ============================================================

  def monad_pure(value), do: fn state -> {value, state} end
  def monad_get(), do: fn state -> {state, state} end
  def monad_put(new_state), do: fn _state -> {:ok, new_state} end

  def monad_bind(ma, f) do
    fn state ->
      {a, state2} = ma.(state)
      mb = f.(a)
      mb.(state2)
    end
  end

  def monad_run(ma, initial_state), do: ma.(initial_state)

  def monad_nested(target), do: monad_nested_loop(target)

  defp monad_nested_loop(target) do
    monad_get()
    |> monad_bind(fn n ->
      if n >= target do
        monad_pure(n)
      else
        monad_put(n + 1)
        |> monad_bind(fn _ ->
          monad_nested_loop(target)
        end)
      end
    end)
  end

  # ============================================================
  # Flat evidence-passing - minimal dynamic dispatch baseline
  # ============================================================

  def evf_pure(value), do: fn env -> {value, env} end

  def evf_bind(ma, f) do
    fn env ->
      {a, env2} = ma.(env)
      mb = f.(a)
      mb.(env2)
    end
  end

  def evf_run(ma, initial_env), do: ma.(initial_env)
  def evf_state_get(), do: fn env -> env.state_get.(env) end
  def evf_state_put(value), do: fn env -> env.state_put.(value, env) end

  def evf_with_state(initial_state, computation) do
    fn env ->
      inner_env =
        env
        |> Map.put(:state, initial_state)
        |> Map.put(:state_get, fn inner_env -> {inner_env.state, inner_env} end)
        |> Map.put(:state_put, fn new_state, inner_env ->
          {:ok, %{inner_env | state: new_state}}
        end)

      {result, final_env} = computation.(inner_env)
      {result, Map.drop(final_env, [:state, :state_get, :state_put])}
    end
  end

  def evf_nested(target), do: evf_with_state(0, evf_nested_loop(target))

  defp evf_nested_loop(target) do
    evf_state_get()
    |> evf_bind(fn n ->
      if n >= target do
        evf_pure(n)
      else
        evf_state_put(n + 1)
        |> evf_bind(fn _ ->
          evf_nested_loop(target)
        end)
      end
    end)
  end

  # ============================================================
  # Flat evidence-passing with CPS - isolates CPS overhead
  # ============================================================

  def evf_cps_pure(value), do: fn env, k -> k.(value, env) end

  def evf_cps_bind(ma, f) do
    fn env, k ->
      ma.(env, fn a, env2 ->
        mb = f.(a)
        mb.(env2, k)
      end)
    end
  end

  def evf_cps_run(ma, initial_env), do: ma.(initial_env, fn v, e -> {v, e} end)
  def evf_cps_state_get(), do: fn env, k -> env.state_get.(env, k) end
  def evf_cps_state_put(value), do: fn env, k -> env.state_put.(value, env, k) end

  def evf_cps_with_state(initial_state, computation) do
    fn env, k ->
      inner_env =
        env
        |> Map.put(:state, initial_state)
        |> Map.put(:state_get, fn inner_env, k -> k.(inner_env.state, inner_env) end)
        |> Map.put(:state_put, fn new_state, inner_env, k ->
          k.(:ok, %{inner_env | state: new_state})
        end)

      computation.(inner_env, fn result, final_env ->
        k.(result, Map.drop(final_env, [:state, :state_get, :state_put]))
      end)
    end
  end

  def evf_cps_nested(target), do: evf_cps_with_state(0, evf_cps_nested_loop(target))

  defp evf_cps_nested_loop(target) do
    evf_cps_state_get()
    |> evf_cps_bind(fn n ->
      if n >= target do
        evf_cps_pure(n)
      else
        evf_cps_state_put(n + 1)
        |> evf_cps_bind(fn _ ->
          evf_cps_nested_loop(target)
        end)
      end
    end)
  end

  # ============================================================
  # Skuld implementations
  # ============================================================

  def skuld_nested(target), do: skuld_nested_loop(target)

  defp skuld_nested_loop(target) do
    SkuldState.get()
    |> Comp.bind(fn n ->
      if n >= target do
        Comp.pure(n)
      else
        SkuldState.put(n + 1)
        |> Comp.bind(fn _ ->
          skuld_nested_loop(target)
        end)
      end
    end)
  end

  def skuld_chained(target) do
    base = SkuldState.get()

    Enum.reduce(1..target, base, fn _i, acc ->
      acc
      |> Comp.bind(fn n ->
        if n >= target do
          Comp.pure(n)
        else
          SkuldState.put(n + 1)
          |> Comp.bind(fn _ ->
            SkuldState.get()
          end)
        end
      end)
    end)
  end

  def skuld_fxfasterlist(target) do
    SkuldFxFasterList.fx_each(1..target, fn _i ->
      SkuldState.get()
      |> Comp.bind(fn n ->
        SkuldState.put(n + 1)
      end)
    end)
    |> Comp.bind(fn _ ->
      SkuldState.get()
    end)
  end

  def skuld_fxlist(target) do
    SkuldFxList.fx_each(1..target, fn _i ->
      SkuldState.get()
      |> Comp.bind(fn n ->
        SkuldState.put(n + 1)
      end)
    end)
    |> Comp.bind(fn _ ->
      SkuldState.get()
    end)
  end

  # Yield-based coroutine iteration
  def skuld_yield_loop() do
    SkuldState.get()
    |> Comp.bind(fn n ->
      SkuldState.put(n + 1)
    end)
    |> Comp.bind(fn _ ->
      SkuldYield.yield(:ok)
      |> Comp.bind(fn _input ->
        skuld_yield_loop()
      end)
    end)
  end

  def skuld_yield_wrapped(initial_state) do
    skuld_yield_loop()
    |> SkuldYield.with_handler()
    |> SkuldState.with_handler(initial_state)
  end

  # ============================================================
  # Timing helpers
  # ============================================================

  def time_pure(fun), do: :timer.tc(fun)

  def time_monad(computation, initial_state) do
    :timer.tc(fn -> monad_run(computation, initial_state) end)
  end

  def time_evf(computation) do
    :timer.tc(fn -> evf_run(computation, %{}) end)
  end

  def time_evf_cps(computation) do
    :timer.tc(fn -> evf_cps_run(computation, %{}) end)
  end

  def time_skuld_wrapped(wrapped_computation) do
    :timer.tc(fn -> Comp.run(wrapped_computation) end)
  end

  def skuld_wrap(computation, initial_state) do
    computation |> SkuldState.with_handler(initial_state)
  end

  def time_skuld_yield(target) do
    wrapped = skuld_yield_wrapped(0)

    driver = fn _yielded_value ->
      remaining = Process.get(:yield_iterations)

      if remaining > 1 do
        Process.put(:yield_iterations, remaining - 1)
        {:continue, :ok}
      else
        Process.delete(:yield_iterations)
        {:stop, :done}
      end
    end

    Process.put(:yield_iterations, target)

    :timer.tc(fn ->
      SkuldYield.run_with_driver(wrapped, driver)
    end)
  end

  # ============================================================
  # Benchmark runner
  # ============================================================

  def run_benchmark(targets \\ [500, 1_000, 2_000, 5_000, 10_000]) do
    IO.puts("Skuld Performance Benchmark")
    IO.puts("===========================")
    IO.puts("")
    IO.puts("Comparing Skuld against pure baselines and simple effect implementations.")
    IO.puts("")

    # Warmup
    IO.puts("Warming up...")

    for _ <- 1..3 do
      _ = time_pure(fn -> pure_reduce(100) end)
      _ = time_pure(fn -> pure_recurse(100) end)
      _ = time_monad(monad_nested(100), 0)
      _ = time_evf(evf_nested(100))
      _ = time_evf_cps(evf_cps_nested(100))
      _ = time_skuld_wrapped(skuld_wrap(skuld_nested(100), 0))
      _ = time_skuld_wrapped(skuld_wrap(skuld_chained(100), 0))
      _ = time_skuld_wrapped(skuld_wrap(skuld_fxfasterlist(100), 0))
      _ = time_skuld_yield(100)
    end

    IO.puts("")

    iterations = 5

    IO.puts(
      String.pad_trailing("Target", 8) <>
        String.pad_trailing("Pure/Rec", 12) <>
        String.pad_trailing("Monad", 12) <>
        String.pad_trailing("Evf", 12) <>
        String.pad_trailing("Evf/CPS", 12) <>
        String.pad_trailing("Skuld/Nest", 12) <>
        String.pad_trailing("Skuld/FxFL", 12)
    )

    IO.puts(String.duplicate("-", 80))

    for target <- targets do
      monad_nested_comp = monad_nested(target)
      evf_nested_comp = evf_nested(target)
      evf_cps_nested_comp = evf_cps_nested(target)
      skuld_nested_wrapped = skuld_wrap(skuld_nested(target), 0)
      skuld_fxfasterlist_wrapped = skuld_wrap(skuld_fxfasterlist(target), 0)

      pure_recurse_time =
        median_time(iterations, fn -> time_pure(fn -> pure_recurse(target) end) end)

      monad_nested_time = median_time(iterations, fn -> time_monad(monad_nested_comp, 0) end)
      evf_nested_time = median_time(iterations, fn -> time_evf(evf_nested_comp) end)
      evf_cps_nested_time = median_time(iterations, fn -> time_evf_cps(evf_cps_nested_comp) end)

      skuld_nested_time =
        median_time(iterations, fn -> time_skuld_wrapped(skuld_nested_wrapped) end)

      skuld_fxfasterlist_time =
        median_time(iterations, fn -> time_skuld_wrapped(skuld_fxfasterlist_wrapped) end)

      IO.puts(
        String.pad_trailing("#{target}", 8) <>
          String.pad_trailing(format_time(pure_recurse_time), 12) <>
          String.pad_trailing(format_time(monad_nested_time), 12) <>
          String.pad_trailing(format_time(evf_nested_time), 12) <>
          String.pad_trailing(format_time(evf_cps_nested_time), 12) <>
          String.pad_trailing(format_time(skuld_nested_time), 12) <>
          String.pad_trailing(format_time(skuld_fxfasterlist_time), 12)
      )
    end

    IO.puts("")
    IO.puts("Analysis:")
    IO.puts("---------")
    IO.puts("- Pure/Rec: Non-effectful baseline (recursive function with map state)")
    IO.puts("- Monad: Simple state monad (fn state -> {val, state} end)")
    IO.puts("- Evf: Flat evidence-passing, direct-style (no CPS)")
    IO.puts("- Evf/CPS: Flat evidence-passing with CPS (isolates CPS overhead)")
    IO.puts("- Skuld/Nest: Skuld with nested binds (typical usage)")
    IO.puts("- Skuld/FxFL: Skuld with FxFasterList iteration")

    # ============================================================
    # Yield Benchmark
    # ============================================================
    IO.puts("")
    IO.puts("")
    IO.puts("Yield Benchmark (Coroutine Approach)")
    IO.puts("====================================")
    IO.puts("")
    IO.puts("Yield uses coroutine-style suspend/resume for interruptible iteration.")
    IO.puts("Both FxFasterList and Yield now maintain constant per-op cost at any scale.")
    IO.puts("")

    yield_targets = [1_000, 5_000, 10_000, 50_000, 100_000]

    IO.puts(
      String.pad_trailing("Target", 10) <>
        String.pad_trailing("Skuld/FxFL", 15) <>
        String.pad_trailing("Skuld/Yield", 15) <>
        String.pad_trailing("FxFL µs/op", 12) <>
        String.pad_trailing("Yield µs/op", 12) <>
        String.pad_trailing("FxL/Yield", 10)
    )

    IO.puts(String.duplicate("-", 75))

    for target <- yield_targets do
      skuld_fxfasterlist_wrapped = skuld_wrap(skuld_fxfasterlist(target), 0)

      skuld_fxfasterlist_time =
        median_time(iterations, fn ->
          time_skuld_wrapped(skuld_fxfasterlist_wrapped)
        end)

      skuld_yield_time =
        median_time(iterations, fn ->
          time_skuld_yield(target)
        end)

      fxfasterlist_per_op = skuld_fxfasterlist_time / target
      yield_per_op = skuld_yield_time / target

      yield_speedup =
        if skuld_yield_time > 0, do: skuld_fxfasterlist_time / skuld_yield_time, else: 0

      IO.puts(
        String.pad_trailing("#{target}", 10) <>
          String.pad_trailing(format_time(skuld_fxfasterlist_time), 15) <>
          String.pad_trailing(format_time(skuld_yield_time), 15) <>
          String.pad_trailing("#{Float.round(fxfasterlist_per_op, 3)}", 12) <>
          String.pad_trailing("#{Float.round(yield_per_op, 3)}", 12) <>
          String.pad_trailing("#{Float.round(yield_speedup, 2)}x", 10)
      )
    end

    IO.puts("")
    IO.puts("Yield Analysis:")
    IO.puts("---------------")
    IO.puts("- Both FxFasterList and Yield maintain ~constant per-op cost as N grows")
    IO.puts("- FxFasterList is ~1.7x faster due to lower per-iteration overhead")
    IO.puts("- Use Yield when you need coroutine semantics (suspend/resume, early exit)")
    IO.puts("- Use FxFasterList for simple iteration over collections")

    # ============================================================
    # FxFasterList vs FxList Benchmark
    # ============================================================
    IO.puts("")
    IO.puts("")
    IO.puts("FxFasterList vs FxList Benchmark")
    IO.puts("=================================")
    IO.puts("")
    IO.puts("FxFasterList: Uses Enum.reduce_while, handles control effects explicitly")
    IO.puts("FxList: Uses Comp.bind chains, control effects propagate naturally")
    IO.puts("")
    IO.puts("Key difference: FxList supports full Yield resume semantics.")
    IO.puts("")

    fxlist_targets = [100, 500, 1_000, 2_000, 5_000, 10_000]

    IO.puts(
      String.pad_trailing("Target", 10) <>
        String.pad_trailing("FxFasterList", 15) <>
        String.pad_trailing("FxList", 15) <>
        String.pad_trailing("FxFL µs/op", 12) <>
        String.pad_trailing("FxL µs/op", 12) <>
        String.pad_trailing("FxFL/FxL", 10)
    )

    IO.puts(String.duplicate("-", 75))

    for target <- fxlist_targets do
      skuld_fxfasterlist_wrapped = skuld_wrap(skuld_fxfasterlist(target), 0)
      skuld_fxlist_wrapped = skuld_wrap(skuld_fxlist(target), 0)

      skuld_fxfasterlist_time =
        median_time(iterations, fn ->
          time_skuld_wrapped(skuld_fxfasterlist_wrapped)
        end)

      skuld_fxlist_time =
        median_time(iterations, fn ->
          time_skuld_wrapped(skuld_fxlist_wrapped)
        end)

      fxfasterlist_per_op = skuld_fxfasterlist_time / target
      fxlist_per_op = skuld_fxlist_time / target

      ratio =
        if skuld_fxlist_time > 0,
          do: skuld_fxfasterlist_time / skuld_fxlist_time,
          else: 0

      IO.puts(
        String.pad_trailing("#{target}", 10) <>
          String.pad_trailing(format_time(skuld_fxfasterlist_time), 15) <>
          String.pad_trailing(format_time(skuld_fxlist_time), 15) <>
          String.pad_trailing("#{Float.round(fxfasterlist_per_op, 3)}", 12) <>
          String.pad_trailing("#{Float.round(fxlist_per_op, 3)}", 12) <>
          String.pad_trailing("#{Float.round(ratio, 2)}x", 10)
      )
    end

    IO.puts("")
    IO.puts("FxFasterList vs FxList Analysis:")
    IO.puts("---------------------------------")
    IO.puts("- FxFasterList: Better performance for simple iteration (no control effects)")
    IO.puts("- FxList: Supports full Yield/Suspend resume semantics")
    IO.puts("- Trade-off: FxList builds continuation chains (more allocations)")
    IO.puts("- Recommendation:")
    IO.puts("  - Use FxFasterList for high-performance iteration without Yield")
    IO.puts("  - Use FxList when you need resumable Yield/Suspend (recommended default)")
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

SkuldBenchmark.run_benchmark()
