defmodule Skuld.Effects.Brook do
  @moduledoc """
  High-level streaming API built on channels.

  Stream provides combinators for building streaming pipelines with:
  - Backpressure via bounded channels
  - Automatic error propagation
  - Optional concurrency for transformations
  - Integration with Skuld effects (batching works!)

  ## Basic Usage

      comp do
        source <- Brook.from_enum(1..100)
        mapped <- Brook.map(source, fn x -> x * 2 end)
        filtered <- Brook.filter(mapped, fn x -> rem(x, 4) == 0 end)
        Brook.to_list(filtered)
      end
      |> Channel.with_handler()
      |> FiberPool.with_handler()
      |> Comp.run()

  ## Error Propagation

  Errors automatically flow downstream through channels. If an error occurs
  while processing any value, the stream is immediately errored:

      comp do
        source <- Brook.from_function(fn ->
          case fetch_data() do
            {:ok, items} -> {:items, items}
            {:error, reason} -> {:error, reason}
          end
        end)

        mapped <- Brook.map(source, &process/1)
        Brook.run(mapped, &sink/1)
      end
  """

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Channel
  alias Skuld.Effects.FiberPool

  #############################################################################
  ## Sources
  #############################################################################

  @doc """
  Create a stream from an enumerable.

  Spawns a producer fiber that puts items into the output channel,
  then closes the channel when exhausted.

  ## Options

  - `:buffer` - Output channel capacity (default: 10)

  ## Example

      comp do
        source <- Brook.from_enum(1..100)
        Brook.to_list(source)
      end
  """
  @spec from_enum(Enumerable.t(), keyword()) :: Comp.Types.computation()
  def from_enum(enumerable, opts \\ []) do
    buffer = Keyword.get(opts, :buffer, 10)

    comp do
      output <- Channel.new(buffer)

      _producer <-
        FiberPool.fiber(
          comp do
            produce_items(output, Enum.to_list(enumerable))
          end
        )

      output
    end
  end

  defp produce_items(output, []) do
    comp do
      _close_result <- Channel.close(output)
      :producer_done
    end
  end

  defp produce_items(output, [item | rest]) do
    comp do
      result <- Channel.put(output, item)

      case result do
        :ok -> produce_items(output, rest)
        {:error, _} -> :producer_stopped
      end
    end
  end

  @doc """
  Create a stream from a producer function.

  The producer function is called repeatedly until it signals completion.
  It should return:
  - `{:item, value}` - emit a single item
  - `{:items, [values]}` - emit multiple items
  - `:done` - close the channel normally
  - `{:error, reason}` - signal error to consumers

  ## Options

  - `:buffer` - Output channel capacity (default: 10)

  ## Example

      comp do
        counter = Agent.start_link(fn -> 0 end)

        source <- Brook.from_function(fn ->
          n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
          if n < 10, do: {:item, n}, else: :done
        end)

        Brook.to_list(source)
      end
  """
  @spec from_function(
          (-> {:item, term()} | {:items, [term()]} | :done | {:error, term()}),
          keyword()
        ) ::
          Comp.Types.computation()
  def from_function(producer_fn, opts \\ []) do
    buffer = Keyword.get(opts, :buffer, 10)

    comp do
      output <- Channel.new(buffer)

      _producer <-
        FiberPool.fiber(
          comp do
            produce_from_function(output, producer_fn)
          end
        )

      output
    end
  end

  defp produce_from_function(output, producer_fn) do
    case producer_fn.() do
      {:item, item} ->
        comp do
          result <- Channel.put(output, item)

          case result do
            :ok -> produce_from_function(output, producer_fn)
            {:error, _} -> :producer_stopped
          end
        end

      {:items, items} ->
        produce_items_from_list(output, items, producer_fn)

      :done ->
        close_channel(output, :producer_done)

      {:error, reason} ->
        error_channel(output, reason, :producer_errored)
    end
  end

  defp produce_items_from_list(output, [], producer_fn) do
    produce_from_function(output, producer_fn)
  end

  defp produce_items_from_list(output, [item | rest], producer_fn) do
    comp do
      result <- Channel.put(output, item)

      case result do
        :ok -> produce_items_from_list(output, rest, producer_fn)
        {:error, _} -> :producer_stopped
      end
    end
  end

  #############################################################################
  ## Transformations
  #############################################################################

  @doc """
  Transform each item in the stream.

  Spawns a worker fiber that reads items from input, applies the transform
  function to each, and writes results to output.

  The transform function can be a pure function or return a computation.
  If the transform errors, the stream is errored.

  ## Options

  - `:concurrency` - Maximum concurrent transforms (default: 1). Controls
    how many items can be transformed simultaneously. Uses a bounded channel
    as a semaphore — items acquire a slot before spawning, release when done.
  - `:buffer` - Output channel capacity (default: 10)

  ## Example

      comp do
        source <- Brook.from_enum(1..10)
        doubled <- Brook.map(source, fn x -> x * 2 end)
        Brook.to_list(doubled)
      end

  ## With Effects

  Transform functions can use effects, enabling batching:

      comp do
        source <- Brook.from_enum(user_ids)
        users <- Brook.map(source, fn id -> DB.fetch(User, id) end, concurrency: 10)
        Brook.to_list(users)
      end
      |> DB.with_executors()
  """
  @spec map(
          Channel.Handle.t() | Comp.Types.computation(Channel.Handle.t()),
          (term() -> term() | Comp.Types.computation(term())),
          keyword()
        ) ::
          Comp.Types.computation(Channel.Handle.t())
  def map(input, transform_fn, opts \\ [])

  def map(input, transform_fn, opts) when is_function(input, 2) do
    Comp.bind(input, &map(&1, transform_fn, opts))
  end

  def map(%Channel.Handle{} = input, transform_fn, opts) do
    concurrency = Keyword.get(opts, :concurrency, 1)
    buffer = Keyword.get(opts, :buffer, 10)

    if concurrency < 1 do
      raise ArgumentError, "concurrency must be >= 1, got: #{inspect(concurrency)}"
    end

    comp do
      # Semaphore: bounded channel controls how many items are in flight
      semaphore <- Channel.new(concurrency)
      # Output: reorderer puts ordered results here
      output <- Channel.new(buffer)
      # Intermediate: producer puts fiber handles here, reorderer awaits in order
      intermediate <- Channel.new(concurrency)

      # Producer: reads items, acquires semaphore, spawns transform fibers
      _ <- FiberPool.fiber(map_producer(input, semaphore, intermediate, transform_fn))

      # Reorderer: awaits fibers in put-order, puts results to output
      _ <- FiberPool.fiber(map_reorderer(intermediate, output))

      output
    end
  end

  defp map_producer(input, semaphore, intermediate, transform_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          # Acquire a concurrency slot, spawn transform, then continue
          map_producer_spawn(input, semaphore, intermediate, transform_fn, item)

        :closed ->
          close_channel(intermediate, :producer_done)

        {:error, reason} ->
          error_channel(intermediate, reason, :producer_errored)
      end
    end
  end

  defp map_producer_spawn(input, semaphore, intermediate, transform_fn, item) do
    comp do
      _token <- Channel.put(semaphore, :token)
      _ <- Channel.put_async(intermediate, map_item_transform(item, semaphore, transform_fn))
      map_producer(input, semaphore, intermediate, transform_fn)
    end
  end

  defp map_item_transform(item, semaphore, transform_fn) do
    comp do
      # Run the actual transform
      transform_result <- safe_transform(transform_fn, item)

      # Release the concurrency slot
      _ <- Channel.take(semaphore)

      transform_result
    end
  end

  defp map_reorderer(intermediate, output) do
    comp do
      result <- Channel.take_async(intermediate)

      case result do
        {:ok, {:ok, value}} ->
          map_reorderer_put(intermediate, output, value)

        {:ok, {:error, reason}} ->
          error_channel(output, reason, :map_errored)

        :closed ->
          close_channel(output, :reorderer_done)

        {:error, reason} ->
          error_channel(output, reason, :reorderer_errored)
      end
    end
  end

  defp map_reorderer_put(intermediate, output, value) do
    comp do
      put_result <- Channel.put(output, value)

      case put_result do
        :ok -> map_reorderer(intermediate, output)
        {:error, _} -> :reorderer_stopped
      end
    end
  end

  @doc """
  Map and flatten: `transform_fn` returns a list for each item, and
  the lists are flattened into a single stream.

  Uses the same concurrent semaphore pattern as `map/2`. Supports the
  same `:concurrency` and `:buffer` options.

  ## Example

      [1, 2, 3]
      |> Brook.from_enum()
      |> Brook.flat_map(fn x -> [x, x * 10] end, concurrency: 2)
      |> Brook.to_list()
      # => [1, 10, 2, 20, 3, 30]
  """
  @spec flat_map(
          Channel.Handle.t() | Comp.Types.computation(Channel.Handle.t()),
          (term() -> [term()] | Comp.Types.computation([term()])),
          keyword()
        ) ::
          Comp.Types.computation(Channel.Handle.t())
  def flat_map(input, transform_fn, opts \\ [])

  def flat_map(input, transform_fn, opts) when is_function(input, 2) do
    Comp.bind(input, &flat_map(&1, transform_fn, opts))
  end

  def flat_map(%Channel.Handle{} = input, transform_fn, opts) do
    concurrency = Keyword.get(opts, :concurrency, 1)
    buffer = Keyword.get(opts, :buffer, 10)

    if concurrency < 1 do
      raise ArgumentError, "concurrency must be >= 1, got: #{inspect(concurrency)}"
    end

    comp do
      semaphore <- Channel.new(concurrency)
      output <- Channel.new(buffer)
      intermediate <- Channel.new(concurrency)

      _ <-
        FiberPool.fiber(
          map_producer(input, semaphore, intermediate, fn item ->
            transform_fn.(item)
          end)
        )

      _ <- FiberPool.fiber(flat_map_reorderer(intermediate, output))

      output
    end
  end

  defp flat_map_reorderer(intermediate, output) do
    comp do
      result <- Channel.take_async(intermediate)

      case result do
        {:ok, {:ok, items}} when is_list(items) ->
          flat_map_reorderer_put(intermediate, output, items)

        {:ok, {:error, reason}} ->
          error_channel(output, reason, :map_errored)

        :closed ->
          close_channel(output, :reorderer_done)

        {:error, reason} ->
          error_channel(output, reason, :reorderer_errored)
      end
    end
  end

  defp flat_map_reorderer_put(intermediate, output, items) do
    comp do
      _ <- Channel.put_all(output, items)
      flat_map_reorderer(intermediate, output)
    end
  end

  defp safe_transform(transform_fn, value) do
    result = transform_fn.(value)

    if Comp.computation?(result) do
      comp do
        transformed <- result
        {:ok, transformed}
      end
    else
      {:ok, result}
    end
  rescue
    e -> {:error, {:transform_error, e, __STACKTRACE__}}
  catch
    :throw, reason -> {:error, {:throw, reason}}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Filter items in the stream.

  Only items for which the predicate returns true pass through.

  ## Options

  - `:buffer` - Output channel capacity (default: 10)

  ## Example

      comp do
        source <- Brook.from_enum(1..20)
        evens <- Brook.filter(source, fn x -> rem(x, 2) == 0 end)
        Brook.to_list(evens)
      end
  """
  @spec filter(
          Channel.Handle.t() | Comp.Types.computation(Channel.Handle.t()),
          (term() -> boolean()),
          keyword()
        ) ::
          Comp.Types.computation(Channel.Handle.t())
  def filter(input, pred_fn, opts \\ [])

  def filter(input, pred_fn, opts) when is_function(input, 2) do
    Comp.bind(input, &filter(&1, pred_fn, opts))
  end

  def filter(%Channel.Handle{} = input, pred_fn, opts) do
    buffer = Keyword.get(opts, :buffer, 10)

    comp do
      output <- Channel.new(buffer)

      _worker <-
        FiberPool.fiber(
          comp do
            filter_loop(input, output, pred_fn)
          end
        )

      output
    end
  end

  defp filter_loop(input, output, pred_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          if pred_fn.(item) do
            filter_put_and_loop(input, output, pred_fn, item)
          else
            filter_loop(input, output, pred_fn)
          end

        :closed ->
          close_channel(output, :filter_done)

        {:error, reason} ->
          error_channel(output, reason, :filter_errored)
      end
    end
  end

  defp filter_put_and_loop(input, output, pred_fn, item) do
    comp do
      put_result <- Channel.put(output, item)

      case put_result do
        :ok -> filter_loop(input, output, pred_fn)
        {:error, _} -> :filter_stopped
      end
    end
  end

  #############################################################################
  ## Sinks
  #############################################################################

  @doc ~S"""
  Execute a function for each item in the stream.

  Returns `:ok` when the stream completes successfully, or `{:error, reason}`
  if an error occurred.

  ## Example

      comp do
        source <- Brook.from_enum(1..10)
        Brook.each(source, fn x -> IO.puts("Got: #{x}") end)
      end
  """
  @spec each(
          Channel.Handle.t() | Comp.Types.computation(Channel.Handle.t()),
          (term() -> any())
        ) :: Comp.Types.computation(Channel.Handle.t())
  def each(input, consumer_fn)

  def each(input, consumer_fn) when is_function(input, 2) do
    Comp.bind(input, &each(&1, consumer_fn))
  end

  def each(%Channel.Handle{} = input, consumer_fn) do
    comp do
      handle <- FiberPool.fiber(each_loop(input, consumer_fn))
      FiberPool.await!(handle)
    end
  end

  defp each_loop(input, consumer_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          consumer_fn.(item)
          each_loop(input, consumer_fn)

        :closed ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Run a stream to completion, applying a consumer function to each item.

  Similar to `each/2` but the consumer function can return a computation.
  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Example

      comp do
        source <- Brook.from_enum(records)
        Brook.run(source, fn record -> process_record(record) end)
      end
  """
  @spec run(
          Channel.Handle.t() | Comp.Types.computation(Channel.Handle.t()),
          (term() -> term() | Comp.Types.computation(term()))
        ) :: Comp.Types.computation(Channel.Handle.t())
  def run(input, consumer_fn)

  def run(input, consumer_fn) when is_function(input, 2) do
    Comp.bind(input, &run(&1, consumer_fn))
  end

  def run(%Channel.Handle{} = input, consumer_fn) do
    comp do
      handle <- FiberPool.fiber(run_loop(input, consumer_fn))
      FiberPool.await!(handle)
    end
  end

  defp run_loop(input, consumer_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          run_loop_with_item(input, consumer_fn, item)

        :closed ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_loop_with_item(input, consumer_fn, item) do
    consumer_comp = apply_consumer(consumer_fn, item)

    comp do
      consumer_result <- consumer_comp

      case consumer_result do
        :ok ->
          run_loop(input, consumer_fn)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp apply_consumer(consumer_fn, item) do
    result = consumer_fn.(item)

    if Comp.computation?(result) do
      comp do
        _consumer_value <- result
        :ok
      end
    else
      :ok
    end
  end

  @doc """
  Collect all items from a stream into a list.

  Returns the list on success, or `{:error, reason}` on failure.

  ## Example

      comp do
        source <- Brook.from_enum(1..10)
        mapped <- Brook.map(source, fn x -> x * 2 end)
        Brook.to_list(mapped)
      end
  """
  @spec to_list(Channel.Handle.t() | Comp.Types.computation(Channel.Handle.t())) ::
          Comp.Types.computation([term()])
  def to_list(input)

  def to_list(input) when is_function(input, 2) do
    Comp.bind(input, &to_list/1)
  end

  def to_list(%Channel.Handle{} = input) do
    comp do
      handle <- FiberPool.fiber(to_list_acc(input, []))
      FiberPool.await!(handle)
    end
  end

  defp to_list_acc(input, acc) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          to_list_acc(input, [item | acc])

        :closed ->
          Enum.reverse(acc)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Reduce the stream, threading an accumulator through each item.

  The reducer function receives each item and the current accumulator,
  and returns the new accumulator (or a computation producing it).
  Returns the final accumulator value.

  Sequential by nature — each step depends on the previous result.
  Batching is limited to within-step query blocks.

  ## Example

      comp do
        source <- Brook.from_enum(1..10)
        total <- Brook.reduce(source, 0, fn item, acc -> acc + item end)
      end
  """
  @spec reduce(
          Channel.Handle.t() | Comp.Types.computation(Channel.Handle.t()),
          term(),
          (term(), term() -> term() | Comp.Types.computation(term()))
        ) :: Comp.Types.computation(term())
  def reduce(input, initial_acc, reducer_fn)

  def reduce(input, initial_acc, reducer_fn) when is_function(input, 2) do
    Comp.bind(input, &reduce(&1, initial_acc, reducer_fn))
  end

  def reduce(%Channel.Handle{} = input, initial_acc, reducer_fn) do
    comp do
      handle <- FiberPool.fiber(reduce_acc(input, initial_acc, reducer_fn))
      FiberPool.await!(handle)
    end
  end

  defp reduce_acc(input, acc, reducer_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          reduce_with_item(input, acc, reducer_fn, item)

        :closed ->
          acc

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp reduce_with_item(input, acc, reducer_fn, item) do
    reducer_result = reducer_fn.(item, acc)

    comp do
      new_acc <- reducer_result
      reduce_acc(input, new_acc, reducer_fn)
    end
  end

  #############################################################################
  ## Helpers
  #############################################################################

  defp close_channel(channel, result) do
    comp do
      _close_result <- Channel.close(channel)
      result
    end
  end

  defp error_channel(channel, reason, result) do
    comp do
      _error_result <- Channel.error(channel, reason)
      result
    end
  end
end
