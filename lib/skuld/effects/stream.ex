defmodule Skuld.Effects.Stream do
  @moduledoc """
  High-level streaming API built on channels.

  Stream provides combinators for building streaming pipelines with:
  - Backpressure via bounded channels
  - Automatic error propagation
  - Optional concurrency for transformations
  - Integration with Skuld effects (batching works!)

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

  Errors automatically flow downstream through channels:

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

  #############################################################################
  ## Sources
  #############################################################################

  @doc """
  Create a stream from an enumerable.

  Spawns a producer fiber that puts each item into the output channel,
  then closes the channel when exhausted.

  ## Options

  - `:buffer` - Output channel capacity (default: 10)

  ## Example

      comp do
        source <- Stream.from_enum(1..100)
        Stream.to_list(source)
      end
  """
  @spec from_enum(Enumerable.t(), keyword()) :: Comp.Types.computation()
  def from_enum(enumerable, opts \\ []) do
    buffer = Keyword.get(opts, :buffer, 10)

    comp do
      output <- Channel.new(buffer)

      # Spawn producer fiber
      _producer <-
        FiberPool.fiber(
          comp do
            produce_from_enum(output, Enum.to_list(enumerable))
          end
        )

      Comp.pure(output)
    end
  end

  # Recursive producer for enumerable
  defp produce_from_enum(output, []) do
    comp do
      _close_result <- Channel.close(output)
      Comp.pure(:producer_done)
    end
  end

  defp produce_from_enum(output, [item | rest]) do
    comp do
      result <- Channel.put(output, item)

      case result do
        :ok ->
          produce_from_enum(output, rest)

        {:error, _reason} ->
          # Channel closed or errored, stop producing
          Comp.pure(:producer_stopped)
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

    comp do
      output <- Channel.new(buffer)

      _producer <-
        FiberPool.fiber(
          comp do
            produce_from_function(output, producer_fn)
          end
        )

      Comp.pure(output)
    end
  end

  defp produce_from_function(output, producer_fn) do
    case producer_fn.() do
      {:item, item} ->
        produce_item(output, producer_fn, item)

      {:items, items} ->
        put_items_and_continue(output, items, producer_fn)

      :done ->
        close_channel(output, :producer_done)

      {:error, reason} ->
        error_channel(output, reason, :producer_errored)
    end
  end

  defp produce_item(output, producer_fn, item) do
    comp do
      result <- Channel.put(output, item)

      case result do
        :ok -> produce_from_function(output, producer_fn)
        {:error, _} -> Comp.pure(:producer_stopped)
      end
    end
  end

  defp put_items_and_continue(output, [], producer_fn) do
    produce_from_function(output, producer_fn)
  end

  defp put_items_and_continue(output, [item | rest], producer_fn) do
    comp do
      result <- Channel.put(output, item)

      case result do
        :ok -> put_items_and_continue(output, rest, producer_fn)
        {:error, _} -> Comp.pure(:producer_stopped)
      end
    end
  end

  #############################################################################
  ## Transformations
  #############################################################################

  @doc """
  Transform each item in the stream.

  Spawns worker fiber(s) that read from input, apply the transform function,
  and write to output. The transform function can be a pure function or
  return a computation.

  ## Options

  - `:concurrency` - Number of worker fibers (default: 1)
  - `:buffer` - Output channel capacity (default: 10)

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

    comp do
      output <- Channel.new(buffer)

      # Use atomic counter to track when all workers are done
      # When the last worker finishes, it closes the output channel
      remaining_workers = :atomics.new(1, [])
      _ = :atomics.put(remaining_workers, 1, concurrency)

      # Spawn worker fibers
      _workers <-
        spawn_workers(concurrency, fn ->
          map_worker(input, output, transform_fn, remaining_workers)
        end)

      Comp.pure(output)
    end
  end

  defp map_worker(input, output, transform_fn, remaining_workers) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          map_transform_item(input, output, transform_fn, item, remaining_workers)

        :closed ->
          # Input exhausted - decrement counter and maybe close output
          map_worker_done(output, remaining_workers)

        {:error, reason} ->
          # Input errored - propagate downstream
          error_channel(output, reason, :worker_errored)
      end
    end
  end

  defp map_worker_done(output, remaining_workers) do
    # Decrement counter and check if we're the last worker
    new_count = :atomics.sub_get(remaining_workers, 1, 1)

    if new_count == 0 do
      # Last worker - close the output channel
      close_channel(output, :worker_done)
    else
      Comp.pure(:worker_done)
    end
  end

  defp map_transform_item(input, output, transform_fn, item, remaining_workers) do
    comp do
      transformed <- try_transform(transform_fn, item)

      case transformed do
        {:ok, value} ->
          map_put_result(input, output, transform_fn, value, remaining_workers)

        {:error, reason} ->
          # Transform failed - propagate error downstream
          error_channel(output, reason, :worker_errored)
      end
    end
  end

  defp map_put_result(input, output, transform_fn, value, remaining_workers) do
    comp do
      put_result <- Channel.put(output, value)

      case put_result do
        :ok -> map_worker(input, output, transform_fn, remaining_workers)
        {:error, _} -> Comp.pure(:worker_stopped)
      end
    end
  end

  defp try_transform(transform_fn, item) do
    # Check if the transform returns a computation or a plain value
    result = transform_fn.(item)

    if is_function(result, 2) do
      # It's a computation - bind it
      comp do
        value <- result
        Comp.pure({:ok, value})
      end
    else
      # Plain value - wrap it
      Comp.pure({:ok, result})
    end
  end

  @doc """
  Filter items in the stream.

  Only items for which the predicate returns true pass through.

  ## Options

  - `:buffer` - Output channel capacity (default: 10)

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
        {:ok, item} ->
          filter_item(input, output, pred_fn, item)

        :closed ->
          close_channel(output, :filter_done)

        {:error, reason} ->
          error_channel(output, reason, :filter_errored)
      end
    end
  end

  defp filter_item(input, output, pred_fn, item) do
    if pred_fn.(item) do
      filter_put_item(input, output, pred_fn, item)
    else
      filter_loop(input, output, pred_fn)
    end
  end

  defp filter_put_item(input, output, pred_fn, item) do
    comp do
      put_result <- Channel.put(output, item)

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
    # Run consumer in a fiber so channel operations work
    comp do
      handle <- FiberPool.fiber(each_loop(input, consumer_fn))
      FiberPool.await(handle)
    end
  end

  defp each_loop(input, consumer_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          _ = consumer_fn.(item)
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
    # Run consumer in a fiber so channel operations work
    comp do
      handle <- FiberPool.fiber(run_loop(input, consumer_fn))
      FiberPool.await(handle)
    end
  end

  defp run_loop(input, consumer_fn) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          run_consume_item(input, consumer_fn, item)

        :closed ->
          Comp.pure(:ok)

        {:error, reason} ->
          Comp.pure({:error, reason})
      end
    end
  end

  defp run_consume_item(input, consumer_fn, item) do
    comp do
      consumer_result <- apply_consumer(consumer_fn, item)

      case consumer_result do
        :ok ->
          run_loop(input, consumer_fn)

        {:error, reason} ->
          Comp.pure({:error, reason})
      end
    end
  end

  defp apply_consumer(consumer_fn, item) do
    result = consumer_fn.(item)

    if is_function(result, 2) do
      # It's a computation
      comp do
        _consumer_value <- result
        Comp.pure(:ok)
      end
    else
      # Plain value - just succeed
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
    # Run consumer in a fiber so channel operations work
    comp do
      handle <- FiberPool.fiber(to_list_acc(input, []))
      FiberPool.await(handle)
    end
  end

  defp to_list_acc(input, acc) do
    comp do
      result <- Channel.take(input)

      case result do
        {:ok, item} ->
          to_list_acc(input, acc ++ [item])

        :closed ->
          Comp.pure(acc)

        {:error, reason} ->
          Comp.pure({:error, reason})
      end
    end
  end

  #############################################################################
  ## Helpers
  #############################################################################

  defp spawn_workers(count, worker_fn) do
    spawn_workers_acc(count, worker_fn, [])
  end

  defp spawn_workers_acc(0, _worker_fn, acc) do
    Comp.pure(Enum.reverse(acc))
  end

  defp spawn_workers_acc(count, worker_fn, acc) do
    comp do
      handle <- FiberPool.fiber(worker_fn.())
      spawn_workers_acc(count - 1, worker_fn, [handle | acc])
    end
  end

  # Helper to close a channel and return a result
  defp close_channel(channel, result) do
    comp do
      _close_result <- Channel.close(channel)
      Comp.pure(result)
    end
  end

  # Helper to error a channel and return a result
  defp error_channel(channel, reason, result) do
    comp do
      _error_result <- Channel.error(channel, reason)
      Comp.pure(result)
    end
  end
end
