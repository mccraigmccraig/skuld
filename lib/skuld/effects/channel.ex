defmodule Skuld.Effects.Channel do
  @moduledoc """
  Bounded channel with suspending put/take operations and error propagation.

  Channels provide backpressure-aware communication between fibers:
  - When a channel is full, `put` suspends the fiber until space is available
  - When a channel is empty, `take` suspends the fiber until an item arrives
  - Error state propagates to all consumers (sticky error)

  ## Channel States

  - `:open` - normal operation
  - `:closed` - producer finished normally (consumers drain buffer then get `:closed`)
  - `{:error, reason}` - producer failed, error propagates to all consumers

  ## Usage

  Channels must be run within a FiberPool with the channel handler installed:

      comp do
        ch <- Channel.new(10)

        # Producer fiber
        producer <- FiberPool.fiber(comp do
          Enum.each(1..100, fn i ->
            _ <- Channel.put(ch, i)  # Suspends if buffer full
          end)
          Channel.close(ch)
        end)

        # Consumer fiber
        consumer <- FiberPool.fiber(comp do
          consume_loop(ch)
        end)

        FiberPool.await_all!([producer, consumer])
      end
      |> Channel.with_handler()
      |> FiberPool.with_handler()
      |> FiberPool.run()

  ## Error Propagation

  When a producer encounters an error, it can signal this to consumers:

      case fetch_data() do
        {:ok, items} ->
          Enum.each(items, fn i -> Channel.put(ch, i) end)
          Channel.close(ch)
        {:error, reason} ->
          Channel.error(ch, reason)  # All consumers will see this error!
      end

  Consumers will receive `{:error, reason}` from `take` when the channel
  is in error state. The error is "sticky" - it doesn't get lost.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Fiber.FiberPool.EnvState
  alias Skuld.Effects.Channel.State

  #############################################################################
  ## Handle Struct
  #############################################################################

  defmodule Handle do
    @moduledoc """
    Opaque handle to a channel.

    The handle contains only the channel ID - the actual channel state
    is stored in the computation environment.
    """

    @type t :: %__MODULE__{
            id: reference()
          }

    defstruct [:id]

    @doc false
    def new(id) do
      %__MODULE__{id: id}
    end
  end

  #############################################################################
  ## Channel Creation
  #############################################################################

  @doc """
  Create a new bounded channel with the given capacity.

  The capacity must be a positive integer. Returns a `Channel.Handle`
  that can be used for put/take operations.

  ## Example

      comp do
        ch <- Channel.new(10)
        # ch is now a Channel.Handle
      end
  """
  @spec new(non_neg_integer()) :: Comp.Types.computation()
  def new(capacity) when is_integer(capacity) and capacity >= 0 do
    fn env, k ->
      state = State.new(capacity)
      env = register_channel(env, state)
      k.(Handle.new(state.id), env)
    end
  end

  #############################################################################
  ## Put Operations
  #############################################################################

  @doc """
  Put an item into the channel.

  Returns:
  - `:ok` - item was put successfully
  - `{:error, :closed}` - channel is closed
  - `{:error, reason}` - channel is in error state

  If the channel buffer is full, the fiber suspends until space is available.
  If there are waiting takers, the item is handed off directly.

  ## Example

      comp do
        result <- Channel.put(ch, item)
        case result do
          :ok -> # item was put
          {:error, reason} -> # channel closed or errored
        end
      end
  """
  @spec put(Handle.t(), term()) :: Comp.Types.computation()
  def put(%Handle{id: channel_id}, item) do
    fn env, k ->
      state = get_channel(env, channel_id)

      case state.status do
        {:error, reason} ->
          # Channel errored - reject put
          k.({:error, reason}, env)

        :closed ->
          # Channel closed - reject put
          k.({:error, :closed}, env)

        :open ->
          cond do
            State.has_waiting_takes?(state) ->
              # Direct handoff to waiting taker
              {:ok, taker_fid, state} = State.pop_waiting_take(state)
              env = update_channel(env, channel_id, state)

              # Create a wake request for the taker
              env = add_channel_wake(env, taker_fid, {:ok, item})

              # Put succeeds immediately
              k.(:ok, env)

            State.buffer_full?(state) ->
              # Buffer full - suspend until space available
              fiber_id = get_fiber_id(env)

              # Add to waiting puts list so take() can find and wake us
              state = State.add_waiting_put(state, fiber_id, item)
              env = update_channel(env, channel_id, state)

              # Resume fn is stored in fiber.suspended_k, not duplicated here
              resume_fn = fn result, resume_env -> k.(result, resume_env) end
              suspend = InternalSuspend.channel_put(channel_id, item, resume_fn)

              {suspend, env}

            true ->
              # Add to buffer
              state = State.enqueue(state, item)
              env = update_channel(env, channel_id, state)
              k.(:ok, env)
          end
      end
    end
  end

  #############################################################################
  ## Take Operations
  #############################################################################

  @doc """
  Take an item from the channel.

  Returns:
  - `{:ok, item}` - got an item
  - `:closed` - channel is closed and buffer is empty
  - `{:error, reason}` - channel is in error state (sticky!)

  If the channel buffer is empty and the channel is open, the fiber
  suspends until an item is available.

  ## Example

      comp do
        case Channel.take(ch) do
          {:ok, item} -> # process item
          :closed -> # channel finished
          {:error, reason} -> # error from producer
        end
      end
  """
  @spec take(Handle.t()) :: Comp.Types.computation()
  def take(%Handle{id: channel_id}) do
    fn env, k ->
      state = get_channel(env, channel_id)

      case state.status do
        {:error, reason} ->
          # Channel errored - always return error (sticky!)
          k.({:error, reason}, env)

        _ ->
          cond do
            not State.buffer_empty?(state) ->
              # Take from buffer
              {:ok, item, state} = State.dequeue(state)

              # Maybe wake a waiting putter
              {state, env} = maybe_wake_putter(state, channel_id, env)

              env = update_channel(env, channel_id, state)
              k.({:ok, item}, env)

            State.has_waiting_puts?(state) ->
              # Direct handoff from waiting putter
              {:ok, {putter_fid, item}, state} = State.pop_waiting_put(state)
              env = update_channel(env, channel_id, state)

              # Wake the putter with success
              env = add_channel_wake(env, putter_fid, :ok)

              k.({:ok, item}, env)

            state.status == :closed ->
              # Channel closed and buffer empty
              k.(:closed, env)

            true ->
              # Buffer empty, channel open - suspend until item available
              fiber_id = get_fiber_id(env)

              # Add to waiting takes list so put() can find and wake us
              state = State.add_waiting_take(state, fiber_id)
              env = update_channel(env, channel_id, state)

              # Resume fn is stored in fiber.suspended_k, not duplicated here
              resume_fn = fn result, resume_env -> k.(result, resume_env) end
              suspend = InternalSuspend.channel_take(channel_id, resume_fn)

              {suspend, env}
          end
      end
    end
  end

  #############################################################################
  ## Async Put/Take Operations
  #############################################################################

  @doc """
  Put a computation into the channel asynchronously.

  Spawns a fiber to execute the computation and stores the fiber handle
  in the channel buffer. This enables ordered concurrent processing -
  computations execute concurrently but results are taken in put-order.

  Returns:
  - `:ok` - fiber was spawned and handle stored
  - `{:error, :closed}` - channel is closed
  - `{:error, reason}` - channel is in error state

  If the buffer is full, suspends until space is available (backpressure).
  The buffer size naturally limits the number of concurrent computations.

  ## Example

      comp do
        ch <- Channel.new(10)  # max 10 concurrent transforms

        # Producer puts computations - they start executing immediately
        _ <- Channel.put_async(ch, expensive_transform(item1))
        _ <- Channel.put_async(ch, expensive_transform(item2))

        # Consumer takes resolved values in put-order
        {:ok, result1} <- Channel.take_async(ch)
        {:ok, result2} <- Channel.take_async(ch)
      end
  """
  @spec put_async(Handle.t(), Comp.Types.computation()) :: Comp.Types.computation()
  def put_async(%Handle{} = handle, computation) do
    use Skuld.Syntax
    alias Skuld.Effects.FiberPool

    comp do
      # Spawn fiber for the computation
      fiber_handle <- FiberPool.fiber(computation)

      # Store the fiber handle in the buffer (normal put semantics)
      put(handle, {:__channel_async_fiber__, fiber_handle})
    end
  end

  @doc """
  Take from a channel with async fibers, awaiting the result.

  Takes a fiber handle from the buffer and awaits its completion.
  Returns the fiber's result value, preserving put-order even when
  computations complete out of order.

  Returns:
  - `{:ok, value}` - fiber completed successfully with value
  - `:closed` - channel is closed and buffer is empty
  - `{:error, reason}` - channel errored OR fiber failed

  ## Example

      comp do
        input <- Stream.from_enum(items)
        output <- Channel.new(10)

        # Producer: put_async spawns transform fibers
        _ <- FiberPool.fiber(comp do
          Stream.each(input, fn item ->
            Channel.put_async(output, transform(item))
          end)
          Channel.close(output)
        end)

        # Consumer: take_async awaits in order
        collect_async_results(output, [])
      end

  ## Mixed Usage

  If a non-async item is taken (one not put via `put_async`), it is
  returned as `{:ok, item}` without awaiting.
  """
  @spec take_async(Handle.t()) :: Comp.Types.computation()
  def take_async(%Handle{} = handle) do
    use Skuld.Syntax
    alias Skuld.Effects.FiberPool

    comp do
      result <- take(handle)

      case result do
        {:ok, {:__channel_async_fiber__, fiber_handle}} ->
          # Await and consume the fiber - single-consumer pattern for streaming
          FiberPool.await_consume(fiber_handle)

        {:ok, other} ->
          # Not an async fiber - return as-is (allows mixed usage)
          Comp.pure({:ok, other})

        :closed ->
          Comp.pure(:closed)

        {:error, reason} ->
          Comp.pure({:error, reason})
      end
    end
  end

  #############################################################################
  ## Peek Operation
  #############################################################################

  @doc """
  Peek at the next item without removing it.

  Returns:
  - `{:ok, item}` - next item in buffer
  - `:empty` - buffer is empty (channel still open)
  - `:closed` - channel is closed and buffer is empty
  - `{:error, reason}` - channel is in error state

  Unlike `take`, `peek` never suspends.

  ## Example

      comp do
        case Channel.peek(ch) do
          {:ok, item} -> # item is available but not removed
          :empty -> # no items but channel is open
          :closed -> # channel finished
          {:error, reason} -> # error
        end
      end
  """
  @spec peek(Handle.t()) :: Comp.Types.computation()
  def peek(%Handle{id: channel_id}) do
    fn env, k ->
      state = get_channel(env, channel_id)

      case state.status do
        {:error, reason} ->
          k.({:error, reason}, env)

        _ ->
          case State.peek(state) do
            {:ok, item} ->
              k.({:ok, item}, env)

            :empty when state.status == :closed ->
              k.(:closed, env)

            :empty ->
              k.(:empty, env)
          end
      end
    end
  end

  #############################################################################
  ## Termination Operations
  #############################################################################

  @doc """
  Close the channel (signal normal completion).

  After closing:
  - New `put` operations return `{:error, :closed}`
  - `take` continues to drain the buffer, then returns `:closed`
  - Waiting takers (when buffer empty) are woken with `:closed`

  Close is idempotent - closing an already closed or errored channel is a no-op.

  ## Example

      comp do
        # Producer finishes
        _ <- Channel.close(ch)
        :ok
      end
  """
  @spec close(Handle.t()) :: Comp.Types.computation()
  def close(%Handle{id: channel_id}) do
    fn env, k ->
      state = get_channel(env, channel_id)

      case state.status do
        :open ->
          state = State.close(state)

          # If buffer is empty, wake all waiting takers with :closed
          env =
            if State.buffer_empty?(state) do
              {waiting_takes, state_cleared} = State.pop_all_waiting_takes(state)
              state = state_cleared

              Enum.reduce(waiting_takes, update_channel(env, channel_id, state), fn fid,
                                                                                    acc_env ->
                add_channel_wake(acc_env, fid, :closed)
              end)
            else
              update_channel(env, channel_id, state)
            end

          k.(:ok, env)

        _ ->
          # Already closed or errored - no-op
          k.(:ok, env)
      end
    end
  end

  @doc """
  Put the channel into error state.

  After erroring:
  - All waiting takers are woken with `{:error, reason}`
  - All waiting putters are woken with `{:error, reason}`
  - All future `take` operations return `{:error, reason}` (sticky!)
  - All future `put` operations return `{:error, reason}`

  Error is idempotent - first error wins.

  ## Example

      comp do
        case fetch_data() do
          {:ok, data} -> process(data)
          {:error, reason} ->
            # Propagate error to all consumers
            _ <- Channel.error(ch, reason)
        end
      end
  """
  @spec error(Handle.t(), term()) :: Comp.Types.computation()
  def error(%Handle{id: channel_id}, reason) do
    fn env, k ->
      state = get_channel(env, channel_id)

      case state.status do
        :open ->
          state = State.error(state, reason)

          # Wake all waiting takers with the error
          {waiting_takes, state} = State.pop_all_waiting_takes(state)

          env =
            Enum.reduce(waiting_takes, env, fn fid, acc_env ->
              add_channel_wake(acc_env, fid, {:error, reason})
            end)

          # Wake all waiting putters with the error
          {waiting_puts, state} = State.pop_all_waiting_puts(state)

          env =
            Enum.reduce(waiting_puts, env, fn {fid, _item}, acc_env ->
              add_channel_wake(acc_env, fid, {:error, reason})
            end)

          env = update_channel(env, channel_id, state)
          k.(:ok, env)

        _ ->
          # Already closed or errored - no-op
          k.(:ok, env)
      end
    end
  end

  #############################################################################
  ## Inspection
  #############################################################################

  @doc """
  Check if the channel is closed.
  """
  @spec closed?(Handle.t()) :: Comp.Types.computation()
  def closed?(%Handle{id: channel_id}) do
    fn env, k ->
      state = get_channel(env, channel_id)
      k.(State.closed?(state), env)
    end
  end

  @doc """
  Check if the channel is in error state.
  """
  @spec errored?(Handle.t()) :: Comp.Types.computation()
  def errored?(%Handle{id: channel_id}) do
    fn env, k ->
      state = get_channel(env, channel_id)
      k.(State.errored?(state), env)
    end
  end

  @doc """
  Get channel statistics (for debugging/metrics).
  """
  @spec stats(Handle.t()) :: Comp.Types.computation()
  def stats(%Handle{id: channel_id}) do
    fn env, k ->
      state = get_channel(env, channel_id)
      k.(State.stats(state), env)
    end
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install the channel handler for a computation.

  This initializes the channel state storage.
  Must be used before any channel operations.

  ## Example

      comp do
        ch <- Channel.new(10)
        # ... channel operations
      end
      |> Channel.with_handler()
      |> FiberPool.with_handler()
      |> FiberPool.run()
  """
  @spec with_handler(Comp.Types.computation()) :: Comp.Types.computation()
  def with_handler(comp) do
    fn env, k ->
      # Initialize EnvState in env.state if not present
      env =
        if Env.get_state(env, EnvState.env_key()) == nil do
          Env.put_state(env, EnvState.env_key(), EnvState.new())
        else
          env
        end

      Comp.call(comp, env, k)
    end
  end

  #############################################################################
  ## Internal: Channel State Management (via EnvState)
  #############################################################################

  defp register_channel(env, state) do
    update_env_state(env, &EnvState.register_channel(&1, state))
  end

  defp get_channel(env, channel_id) do
    env_state = get_env_state(env)
    EnvState.get_channel!(env_state, channel_id)
  end

  defp update_channel(env, channel_id, state) do
    update_env_state(env, &EnvState.put_channel(&1, channel_id, state))
  end

  #############################################################################
  ## Internal: Fiber ID and Wake Management (via EnvState)
  #############################################################################

  # Get the current fiber ID from the environment
  defp get_fiber_id(env) do
    env_state = get_env_state(env)
    EnvState.get_fiber_id!(env_state)
  end

  # Add a channel wake request to env.state
  # The FiberPool scheduler will process these to wake suspended fibers
  defp add_channel_wake(env, fiber_id, result) do
    update_env_state(env, &EnvState.add_channel_wake(&1, fiber_id, result))
  end

  # Wake a putter if one is waiting (after a take frees space)
  defp maybe_wake_putter(state, _channel_id, env) do
    if State.has_waiting_puts?(state) and not State.buffer_full?(state) do
      {:ok, {putter_fid, item}, state} = State.pop_waiting_put(state)
      # Add the item to the buffer
      state = State.enqueue(state, item)
      # Wake the putter
      env = add_channel_wake(env, putter_fid, :ok)
      {state, env}
    else
      {state, env}
    end
  end

  #############################################################################
  ## Internal: EnvState Helpers
  #############################################################################

  defp get_env_state(env) do
    Env.get_state(env, EnvState.env_key(), EnvState.new())
  end

  defp update_env_state(env, fun) do
    env_state = get_env_state(env)
    env_state = fun.(env_state)
    Env.put_state(env, EnvState.env_key(), env_state)
  end
end
