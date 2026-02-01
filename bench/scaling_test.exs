# Test: Does Skuld Stream scale linearly with input size?

alias Skuld.Effects.Stream, as: S
alias Skuld.Effects.Channel
alias Skuld.Effects.FiberPool

defmodule ScalingTest do
  use Skuld.Syntax

  def run(n, num_stages) do
    build_pipeline(n, num_stages)
    |> Channel.with_handler()
    |> FiberPool.with_handler()
    |> FiberPool.run!()
  end

  defp build_pipeline(n, num_stages) do
    comp do
      source <- S.from_enum(1..n, chunk_size: 100, buffer: 10)
      final <- apply_stages(source, num_stages)
      S.each(final, fn _x -> :ok end)
    end
  end

  defp apply_stages(source, 0), do: Skuld.Comp.pure(source)

  defp apply_stages(source, n) do
    comp do
      next <- S.map(source, fn x -> x + 1 end, buffer: 10)
      apply_stages(next, n - 1)
    end
  end

  def time_run(n, num_stages, iterations \\ 3) do
    # Warmup
    run(n, num_stages)
    :erlang.garbage_collect()

    times =
      for _ <- 1..iterations do
        {time, _} = :timer.tc(fn -> run(n, num_stages) end)
        :erlang.garbage_collect()
        time
      end

    avg = Enum.sum(times) / iterations
    {avg / 1000, Enum.min(times) / 1000, Enum.max(times) / 1000}
  end
end

IO.puts("Scaling Test: Time vs Input Size")
IO.puts("=" |> String.duplicate(60))

for stages <- [1, 5] do
  IO.puts("\n#{stages} Stage(s):")
  IO.puts("-" |> String.duplicate(40))

  results =
    for n <- [100, 500, 1000, 2000, 5000, 10000] do
      {avg, min, max} = ScalingTest.time_run(n, stages)
      per_item = avg / n
      IO.puts("  #{String.pad_leading(Integer.to_string(n), 5)} items: #{Float.round(avg, 2)} ms (#{Float.round(per_item, 4)} ms/item)")
      {n, avg, per_item}
    end

  # Check scaling factor
  [{n1, t1, _}, {n2, t2, _}] = Enum.take(results, -2)
  expected = t1 * (n2 / n1)
  actual_ratio = t2 / t1
  expected_ratio = n2 / n1
  IO.puts("\n  Scaling from #{n1} to #{n2}:")
  IO.puts("    Expected: #{Float.round(expected, 2)} ms (#{expected_ratio}x)")
  IO.puts("    Actual:   #{Float.round(t2, 2)} ms (#{Float.round(actual_ratio, 2)}x)")
end
