# Benchmark: Skuld Streams vs GenStage
#
# Compares multi-stage pipelines with backpressure.
# Each stage just increments the integer it received.
#
# Run with: mix run bench/stream_vs_genstage.exs

alias Skuld.Effects.Stream, as: S
alias Skuld.Effects.Channel
alias Skuld.Effects.FiberPool

# =============================================================================
# GenStage Modules
# =============================================================================

defmodule Bench.GS.Producer do
  use GenStage

  def start_link(enumerable) do
    GenStage.start_link(__MODULE__, enumerable)
  end

  def init(enumerable) do
    {:producer, Enum.to_list(enumerable)}
  end

  def handle_demand(demand, items) when demand > 0 do
    {to_send, remaining} = Enum.split(items, demand)
    {:noreply, to_send, remaining}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, [], state}
  end
end

defmodule Bench.GS.Stage do
  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  def init(opts) do
    {:producer_consumer, :ok, opts}
  end

  def handle_events(events, _from, state) do
    # Simple increment
    processed = Enum.map(events, &(&1 + 1))
    {:noreply, processed, state}
  end
end

defmodule Bench.GS.CollectingConsumer do
  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  def init(opts) do
    {:consumer, [], opts}
  end

  def handle_events(events, _from, acc) do
    {:noreply, [], acc ++ events}
  end

  def handle_call(:get_results, _from, acc) do
    {:reply, acc, [], []}
  end
end

# =============================================================================
# GenStage Pipeline Builder
# =============================================================================

defmodule Bench.GenStagePipeline do
  @doc """
  Build and run a GenStage pipeline with N stages.
  Returns the collected results.
  """
  def run(enumerable, num_stages, buffer_size \\ 100) do
    # Start producer
    {:ok, producer} = Bench.GS.Producer.start_link(enumerable)

    # Start intermediate stages, building up the chain
    last_stage =
      Enum.reduce(1..num_stages, producer, fn _i, prev ->
        {:ok, stage} =
          Bench.GS.Stage.start_link(
            subscribe_to: [{prev, max_demand: buffer_size, min_demand: div(buffer_size, 2)}]
          )

        stage
      end)

    # Start collecting consumer
    {:ok, consumer} =
      Bench.GS.CollectingConsumer.start_link(
        subscribe_to: [{last_stage, max_demand: buffer_size, min_demand: div(buffer_size, 2)}]
      )

    # Wait for pipeline to complete by polling
    wait_for_completion(producer, consumer)
  end

  defp wait_for_completion(producer, consumer) do
    case GenStage.call(producer, :get_state, 30_000) do
      [] ->
        # Producer empty, give consumer time to finish
        Process.sleep(50)
        GenStage.call(consumer, :get_results, 30_000)

      _ ->
        Process.sleep(1)
        wait_for_completion(producer, consumer)
    end
  end
end

# =============================================================================
# Skuld Stream Pipeline Builder
# =============================================================================

defmodule Bench.SkuldPipeline do
  use Skuld.Syntax
  alias Skuld.Comp

  @doc """
  Build and run a Skuld Stream pipeline with N stages.
  Returns the collected results.
  """
  def run(enumerable, num_stages, buffer_size \\ 100) do
    build_pipeline(enumerable, num_stages, buffer_size)
    |> Channel.with_handler()
    |> FiberPool.with_handler()
    |> FiberPool.run!()
  end

  defp build_pipeline(enumerable, num_stages, buffer_size) do
    comp do
      source <- S.from_enum(enumerable, buffer: buffer_size)
      final <- apply_stages(source, num_stages, buffer_size)
      S.to_list(final)
    end
  end

  defp apply_stages(source, 0, _buffer_size) do
    Comp.pure(source)
  end

  defp apply_stages(source, n, buffer_size) do
    comp do
      next <- S.map(source, fn x -> x + 1 end, buffer: buffer_size)
      apply_stages(next, n - 1, buffer_size)
    end
  end
end

# =============================================================================
# Benchmark
# =============================================================================

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("Skuld Streams vs GenStage Benchmark")
IO.puts("Each stage increments an integer by 1")
IO.puts(String.duplicate("=", 70) <> "\n")

# Configuration
buffer_size = 100

# Verify correctness first
IO.puts("Verifying correctness...")

test_input = 1..100
expected = Enum.map(test_input, &(&1 + 3))

skuld_result = Bench.SkuldPipeline.run(test_input, 3, 10)
genstage_result = Bench.GenStagePipeline.run(test_input, 3, 10)

if skuld_result == expected do
  IO.puts("  Skuld: OK (order preserved)")
else
  IO.puts("  Skuld: FAILED - got #{inspect(Enum.take(skuld_result, 5))}...")
end

if Enum.sort(genstage_result) == Enum.sort(expected) do
  IO.puts("  GenStage: OK (order may vary)")
else
  IO.puts("  GenStage: FAILED - got #{inspect(Enum.take(genstage_result, 5))}...")
end

IO.puts("")

# Run benchmarks for each configuration
num_stages_list = [1, 5]
input_sizes = [1_000, 10_000, 100_000]

for num_stages <- num_stages_list do
  IO.puts("\n" <> String.duplicate("-", 70))
  IO.puts("#{num_stages} Stage(s)")
  IO.puts(String.duplicate("-", 70))

  for input_size <- input_sizes do
    input = 1..input_size
    size_label = if input_size >= 1_000_000, do: "#{div(input_size, 1_000_000)}M", else: "#{div(input_size, 1000)}k"
    IO.puts("\n  #{size_label} items:")

    Benchee.run(
      %{
        "Skuld" => fn -> Bench.SkuldPipeline.run(input, num_stages, buffer_size) end,
        "GenStage" => fn -> Bench.GenStagePipeline.run(input, num_stages, buffer_size) end
      },
      warmup: 0.5,
      time: 2,
      memory_time: 0.5,
      print: [benchmarking: false, configuration: false]
    )
  end
end

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("Benchmark Complete")
IO.puts(String.duplicate("=", 70))
