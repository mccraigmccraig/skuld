defmodule Skuld.Effects.Stream do
  @moduledoc """
  High-level streaming API built on channels with transparent chunking.

  Stream provides combinators for building streaming pipelines with:
  - Backpressure via bounded channels
  - Automatic error propagation
  - Optional concurrency for transformations
  - Integration with Skuld effects (batching works!)
  - Transparent chunking for efficiency

  ## Transparent Chunking

  Internally, streams operate on chunks of values rather than individual values.
  This is transparent to users - you write operations like `map` and `filter`
  that operate on individual values, and the library handles chunking automatically.

  Chunking dramatically reduces synchronization overhead by batching values
  together, reducing the number of fiber spawns and channel operations.

  ## Basic Usage

      comp do
        # Create a stream from an enumerable
        source <- Stream.from_enum(1..100)

        # Transform with optional concurrency
        mapped <- Stream.map(source, fn x -> x * 2 end, concurrency: 4)

        # Filter
        filtered <- Stream.filter(mapped, fn x -> rem(x, 4) == 0 end)

        # Collect results
        Stream.to_list(filtered)
      end
      |> Channel.with_handler()
      |> FiberPool.with_handler()
      |> FiberPool.run()

  ## Error Propagation

  Errors automatically flow downstream through channels. If an error occurs
  while processing any value in a chunk, the stream is immediately errored:

      comp do
        source <- Stream.from_function(fn ->
          case fetch_data() do
            {:ok, items} -> {:items, items}
            {:error, reason} -> {:error, reason}
          end
        end)

        # If source errors, map sees {:error, reason} and propagates it
        mapped <- Stream.map(source, &process/1)

        # Final result is :ok or {:error, reason}
        Stream.run(mapped, &sink/1)
      end
  """

  use Skuld.Syntax

  alias Skuld.Comp
  alias Skuld.Effects.Channel
  alias Skuld.Effects.FiberPool

  @default_chunk_size 100

  #############################################################################
  ## Chunk Type
  #############################################################################

  defmodule Chunk do
    @moduledoc """
    Internal wrapper for chunked stream values.

    Users don't interact with this directly - it's transparent.
    """
    defstruct [:values]

    @type t :: %__MODULE__{values: [term()]}

    def new(values) when is_list(values), do: %__MODULE__{values: values}

    def chunk?(value), do: match?(%__MODULE__{}, value)

    def values(%__MODULE__{values: vs}), do: vs
  end

  #############################################################################
  ## Sources
  #############################################################################

  @doc """
  Create a stream from an enumerable.

  Spawns a producer fiber that puts chunks of items into the output channel,
  then closes the channel when exhausted.

  ## Options

  - `:buffer` - Output channel capacity in chunks (default: 10)
  - `:chunk_size` - Number of items per chunk (default: 100)

  ## Example

      comp do
        source <- Stream.from_enum(1..100)
        Stream.to_list(source)
      end
  """
  @spec from_enum(Enumerable.t(), keyword()) :: Comp.Types.computation()
  def from_enum(enumerable, opts \\ []) do
    buffer = Keyword.get(opts, :buffer, 10)
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    comp do
      output <- Channel.new(buffer)

      # Spawn producer fiber
      _producer <-
        FiberPool.fiber(
          comp do
            produce_chunks(output, Enum.to_list(enumerable), chunk_size)
          end
        )

      Comp.pure(output)
    end
  end

  # Produce chunks from a list
  defp produce_chunks(output, [], _chunk_size) do
    comp do
      _close_result <- Channel.close(output)
      Comp.pure(:producer_done)
    end
  end

  defp produce_chunks(output, items, chunk_size) do
    {chunk_items, rest} = Enum.split(items, chunk_size)
    chunk = Chunk.new(chunk_items)

    comp do
      result <- Channel.put(output, chunk)

      case result do
        :ok ->
          produce_chunks(output, rest, chunk_size)

        {:error, _reason} ->
          Comp.pure(:producer_stopped)
      end
    end
  end

  @doc """
  Create a stream from a producer function.

  The producer function is called repeatedly until it signals completion.
  It should return:
  - `{:item, value}` - emit a single item
  - `{:items, [values]}` - emit multiple items (will be chunked)
  - `:done` - close the channel normally
  - `{:error, reason}` - signal error to consumers

  ## Options

  - `:buffer` - Output channel capacity in chunks (default: 10)
  - `:chunk_size` - Number of items per chunk (default: 100)

  ## Example

      comp do
        counter = Agent.start_link(fn -> 0 end)

        source <- Stream.from_function(fn ->
          n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
          if n < 10, do: {:item, n}, else: :done
        end)

        Stream.to_list(source)
      end
  """
  @spec from_function(
          (-> {:item, term()} | {:items, [term()]} | :done | {:error, term()}),
          keyword()
        ) ::
          Comp.Types.computation()
  def from_function(producer_fn, opts \\ []) do
    buffer = Keyword.get(opts, :buffer, 10)
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    comp do
      output <- Channel.new(buffer)

      _producer <-
        FiberPool.fiber(
          comp do
            produce_from_function(output, producer_fn, [], chunk_size)
          end
        )

      Comp.pure(output)
    end
  end

  # Accumulate items until we have a full chunk, then emit
  defp produce_from_function(output, producer_fn, acc, chunk_size) do
    case producer_fn.() do
      {:item, item} ->
        new_acc = [item | acc]

        if length(new_acc) >= chunk_size do
          emit_chunk_and_continue(output, producer_fn, Enum.reverse(new_acc), chunk_size)
        else
          produce_from_function(output, producer_fn, new_acc, chunk_size)
        end

      {:items, items} ->
        new_acc = Enum.reverse(items) ++ acc

        if length(new_acc) >= chunk_size do
          {to_emit, remaining} = Enum.split(Enum.reverse(new_acc), chunk_size)
          emit_chunk_and_continue_with_acc(output, producer_fn, to_emit, remaining, chunk_size)
        else
          produce_from_function(output, producer_fn, new_acc, chunk_size)
        end

      :done ->
        # Emit any remaining items as a partial chunk
        if acc == [] do
          close_channel(output, :producer_done)
        else
          emit_final_chunk(output, Enum.reverse(acc))
        end

      {:error, reason} ->
        error_channel(output, reason, :producer_errored)
    end
  end

  defp emit_chunk_and_continue(output, producer_fn, chunk_items, chunk_size) do
    comp do
      result <- Channel.put(output, Chunk.new(chunk_items))

      case result do
        :ok -> produce_from_function(output, producer_fn, [], chunk_size)
        {:error, _} -> Comp.pure(:producer_stopped)
      end
    end
  end

  defp emit_chunk_and_continue_with_acc(output, producer_fn, chunk_items, remaining, chunk_size) do
    comp do
      result <- Channel.put(output, Chunk.new(chunk_items))

      case result do
        :ok -> produce_from_function(output, producer_fn, Enum.reverse(remaining), chunk_size)
        {:error, _} -> Comp.pure(:producer_stopped)
      end
    end
  end

  defp emit_final_chunk(output, chunk_items) do
    comp do
      result <- Channel.put(output, Chunk.new(chunk_items))

      case result do
        :ok -> close_channel(output, :producer_done)
        {:error, _} -> Comp.pure(:producer_stopped)
      end
    end
  end

  #############################################################################
  ## Transformations
  #############################################################################

  @doc """
  Transform each item in the stream.

  Spawns worker fiber(s) that read chunks from input, apply the transform
  function to each item in the chunk, and write result chunks to output.

  The transform function can be a pure function or return a computation.
  If the transform errors on any item in a chunk, the stream is errored.

  ## Options

  - `:concurrency` - Maximum concurrent transforms (default: 1). Due to cooperative
    scheduling, values 1-2 have a floor of 3 concurrent transforms. Values >= 3
    behave as specified.
  - `:buffer` - Output channel capacity in chunks (default: 10)

  ## Example

      comp do
        source <- Stream.from_enum(1..10)
        doubled <- Stream.map(source, fn x -> x * 2 end)
        Stream.to_list(doubled)
      end

  ## With Effects

  Transform functions can use effects, enabling batching:

      comp do
        source <- Stream.from_enum(user_ids)
        users <- Stream.map(source, fn id -> DB.fetch(User, id) end, concurrency: 10)
        Stream.to_list(users)
      end
      |> DB.with_executors()
  """
  @spec map(Channel.Handle.t(), (term() -> term() | Comp.Types.computation()), keyword()) ::
          Comp.Types.computation()
  def map(input, transform_fn, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, 1)
    buffer = Keyword.get(opts, :buffer, 10)

    # Adjust for "hidden" concurrency from spawn-before-put and reorderer consuming.
    # With channel capacity C, actual concurrency is C+2, so we use max(C-2, 1).
    # This means concurrency: 1-2 still gives 3 concurrent (floor), but 3+ is accurate.
    internal_capacity = max(concurrency - 2, 1)

    comp do
      # Intermediate channel holds fiber handles (controls concurrency)
      intermediate <- Channel.new(internal_capacity)
      # Output channel holds final ordered result chunks
      output <- Channel.new(buffer)

      # Producer: reads chunks in order, spawns chunk transforms via put_async
      _ <- FiberPool.fiber(map_producer(input, intermediate, output, transform_fn))

      # Reorderer: awaits chunk transforms in order via take_async, puts to output
      _ <- FiberPool.fiber(map_reorderer(intermediate, output))

      Comp.pure(output)
    end
  end

  # Producer reads chunks from input and spawns transform fibers
  defp map_producer(input, intermediate, output, transform_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, chunk} ->
          map_producer_put_async(input, intermediate, output, transform_fn, chunk)

        :closed ->
          close_channel(intermediate, :producer_done)

        {:error, reason} ->
          error_channel(intermediate, reason, :producer_errored)
      end
    end
  end

  defp map_producer_put_async(input, intermediate, output, transform_fn, chunk) do
    comp do
      put_result <-
        Channel.put_async(intermediate, transform_chunk(chunk, output, transform_fn))

      case put_result do
        :ok -> map_producer(input, intermediate, output, transform_fn)
        {:error, _} -> Comp.pure(:producer_stopped)
      end
    end
  end

  # Transform all values in a chunk, erroring the output channel if any fails
  defp transform_chunk(chunk, output, transform_fn) do
    values = Chunk.values(chunk)

    comp do
      result <- transform_values(values, transform_fn, [])

      case result do
        {:ok, transformed} ->
          Comp.pure(Chunk.new(transformed))

        {:error, reason} ->
          # Error the output channel and return error
          comp do
            _ <- Channel.error(output, reason)
            Comp.pure({:chunk_error, reason})
          end
      end
    end
  end

  # Transform values one by one, stopping on first error
  defp transform_values([], _transform_fn, acc) do
    Comp.pure({:ok, Enum.reverse(acc)})
  end

  defp transform_values([value | rest], transform_fn, acc) do
    comp do
      result <- safe_transform(transform_fn, value)

      case result do
        {:ok, transformed} ->
          transform_values(rest, transform_fn, [transformed | acc])

        {:error, reason} ->
          Comp.pure({:error, reason})
      end
    end
  end

  # Safely apply transform, catching errors
  defp safe_transform(transform_fn, value) do
    try do
      result = transform_fn.(value)

      if is_function(result, 2) do
        # It's a computation - run it and wrap result
        comp do
          transformed <- result
          Comp.pure({:ok, transformed})
        end
      else
        Comp.pure({:ok, result})
      end
    rescue
      e -> Comp.pure({:error, {:transform_error, e, __STACKTRACE__}})
    catch
      :throw, reason -> Comp.pure({:error, {:throw, reason}})
      :exit, reason -> Comp.pure({:error, {:exit, reason}})
    end
  end

  # Reorderer awaits chunk transform results in order and puts to output
  defp map_reorderer(intermediate, output) do
    comp do
      result <- Channel.take_async(intermediate)

      case result do
        {:ok, %Chunk{} = chunk} ->
          map_reorderer_put(intermediate, output, chunk)

        {:ok, {:chunk_error, _reason}} ->
          # Chunk errored, output channel already errored - just stop
          Comp.pure(:reorderer_stopped)

        :closed ->
          close_channel(output, :reorderer_done)

        {:error, reason} ->
          error_channel(output, reason, :reorderer_errored)
      end
    end
  end

  defp map_reorderer_put(intermediate, output, chunk) do
    comp do
      put_result <- Channel.put(output, chunk)

      case put_result do
        :ok -> map_reorderer(intermediate, output)
        {:error, _} -> Comp.pure(:reorderer_stopped)
      end
    end
  end

  @doc """
  Filter items in the stream.

  Only items for which the predicate returns true pass through.
  Filtering happens within chunks - chunks may shrink but are not rechunked.

  ## Options

  - `:buffer` - Output channel capacity in chunks (default: 10)

  ## Example

      comp do
        source <- Stream.from_enum(1..20)
        evens <- Stream.filter(source, fn x -> rem(x, 2) == 0 end)
        Stream.to_list(evens)
      end
  """
  @spec filter(Channel.Handle.t(), (term() -> boolean()), keyword()) ::
          Comp.Types.computation()
  def filter(input, pred_fn, opts \\ []) do
    buffer = Keyword.get(opts, :buffer, 10)

    comp do
      output <- Channel.new(buffer)

      _worker <-
        FiberPool.fiber(
          comp do
            filter_loop(input, output, pred_fn)
          end
        )

      Comp.pure(output)
    end
  end

  defp filter_loop(input, output, pred_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, chunk} ->
          filter_chunk(input, output, pred_fn, chunk)

        :closed ->
          close_channel(output, :filter_done)

        {:error, reason} ->
          error_channel(output, reason, :filter_errored)
      end
    end
  end

  defp filter_chunk(input, output, pred_fn, chunk) do
    filtered_values = Enum.filter(Chunk.values(chunk), pred_fn)

    if filtered_values == [] do
      # Empty chunk after filtering - skip it
      filter_loop(input, output, pred_fn)
    else
      filter_put_chunk(input, output, pred_fn, Chunk.new(filtered_values))
    end
  end

  defp filter_put_chunk(input, output, pred_fn, chunk) do
    comp do
      put_result <- Channel.put(output, chunk)

      case put_result do
        :ok -> filter_loop(input, output, pred_fn)
        {:error, _} -> Comp.pure(:filter_stopped)
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
        source <- Stream.from_enum(1..10)
        Stream.each(source, fn x -> IO.puts("Got: #{x}") end)
      end
  """
  @spec each(Channel.Handle.t(), (term() -> any())) :: Comp.Types.computation()
  def each(input, consumer_fn) do
    comp do
      handle <- FiberPool.fiber(each_loop(input, consumer_fn))
      FiberPool.await!(handle)
    end
  end

  defp each_loop(input, consumer_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, chunk} ->
          # Apply consumer to each value in chunk
          Enum.each(Chunk.values(chunk), consumer_fn)
          each_loop(input, consumer_fn)

        :closed ->
          Comp.pure(:ok)

        {:error, reason} ->
          Comp.pure({:error, reason})
      end
    end
  end

  @doc """
  Run a stream to completion, applying a consumer function to each item.

  Similar to `each/2` but the consumer function can return a computation.
  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Example

      comp do
        source <- Stream.from_enum(records)
        Stream.run(source, fn record -> DB.insert(record) end)
      end
  """
  @spec run(Channel.Handle.t(), (term() -> term() | Comp.Types.computation())) ::
          Comp.Types.computation()
  def run(input, consumer_fn) do
    comp do
      handle <- FiberPool.fiber(run_loop(input, consumer_fn))
      FiberPool.await!(handle)
    end
  end

  defp run_loop(input, consumer_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, chunk} ->
          run_chunk(input, consumer_fn, Chunk.values(chunk))

        :closed ->
          Comp.pure(:ok)

        {:error, reason} ->
          Comp.pure({:error, reason})
      end
    end
  end

  defp run_chunk(input, consumer_fn, []) do
    run_loop(input, consumer_fn)
  end

  defp run_chunk(input, consumer_fn, [value | rest]) do
    comp do
      consumer_result <- apply_consumer(consumer_fn, value)

      case consumer_result do
        :ok ->
          run_chunk(input, consumer_fn, rest)

        {:error, reason} ->
          Comp.pure({:error, reason})
      end
    end
  end

  defp apply_consumer(consumer_fn, item) do
    result = consumer_fn.(item)

    if is_function(result, 2) do
      comp do
        _consumer_value <- result
        Comp.pure(:ok)
      end
    else
      Comp.pure(:ok)
    end
  end

  @doc """
  Collect all items from a stream into a list.

  Returns the list on success, or `{:error, reason}` on failure.

  ## Example

      comp do
        source <- Stream.from_enum(1..10)
        mapped <- Stream.map(source, fn x -> x * 2 end)
        Stream.to_list(mapped)
      end
  """
  @spec to_list(Channel.Handle.t()) :: Comp.Types.computation()
  def to_list(input) do
    comp do
      handle <- FiberPool.fiber(to_list_acc(input, []))
      FiberPool.await!(handle)
    end
  end

  defp to_list_acc(input, acc) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, chunk} ->
          # Prepend chunk values (will reverse at end)
          to_list_acc(input, Enum.reverse(Chunk.values(chunk)) ++ acc)

        :closed ->
          Comp.pure(Enum.reverse(acc))

        {:error, reason} ->
          Comp.pure({:error, reason})
      end
    end
  end

  #############################################################################
  ## Helpers
  #############################################################################

  defp close_channel(channel, result) do
    comp do
      _close_result <- Channel.close(channel)
      Comp.pure(result)
    end
  end

  defp error_channel(channel, reason, result) do
    comp do
      _error_result <- Channel.error(channel, reason)
      Comp.pure(result)
    end
  end
end
