defmodule Skuld.Effects.Cell do
  @moduledoc """
  Single-writer, multi-reader mutable state for concurrent fibers.

  Any fiber can read a Cell; the first fiber to write to a tag claims
  ownership. Only that fiber may write again — writes from other fibers
  error.

  All operations require an explicit tag. There is no default tag.

  ## Usage

      comp do
        # Any fiber can read
        value <- Cell.get(:results)

        # First write claims ownership
        _ <- Cell.put(:results, data)

        # Re-writes by owner are fine
        _ <- Cell.put(:results, new_data)

        # Write from non-owner raises
      end
      |> Cell.with_handler()
      |> FiberPool.with_handler()
      |> Comp.run()
  """

  @behaviour Skuld.Comp.ITotalLinearHandler

  use Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Effects.Channel
  alias Skuld.Effects.FiberPool

  @cell_prefix :cell
  @owner_prefix :cell_owner
  @watcher_prefix :cell_watcher

  def_op get(tag)
  def_op put(tag, value)

  @get_op @__get_op__
  @put_op @__put_op__

  @doc """
  Install the Cell handler for a computation.

  Must be installed inside the FiberPool handler stack (after
  `FiberPool.with_handler/1`) so that `FiberPool.current_fiber_id/1`
  can identify the writing fiber.
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(computation) do
    Comp.with_handler(computation, __MODULE__, &handle/3)
  end

  @doc """
  Watch a Cell tag, returning a Channel that will deliver the value.

  Returns a `Channel.Handle` for a capacity-1 channel:
  - If the Cell has already been written to, the channel contains the
    current value and is closed.
  - If the Cell has not been written to, the channel is empty. When
    `Cell.put/2` writes to the tag, the value is delivered to all
    watcher channels and each channel is closed.

  The returned channel never blocks the writer — capacity 1 with
  immediate close means `Cell.put` always succeeds without suspension.

  Requires `Channel.with_handler/1` to be installed.

  ## Example

      comp do
        watch_fiber <- FiberPool.fiber(comp do
          ch <- Cell.watch(:results)
          Channel.take(ch)
        end)

        writer <- FiberPool.fiber(comp do
          _ <- Cell.put(:results, [1, 2, 3])
          :ok
        end)

        result <- FiberPool.await!(watch_fiber)
        # result == {:ok, [1, 2, 3]}
      end
      |> Cell.with_handler()
      |> Channel.with_handler()
      |> FiberPool.with_handler()
      |> Comp.run()
  """
  @spec watch(term()) :: Types.computation()
  def watch(tag) do
    fn env, k ->
      {handle, env} = Channel.Ops.create(env, 1)

      if Map.has_key?(env.state, {@cell_prefix, tag}) do
        value = Env.get_state(env, {@cell_prefix, tag})
        env = Channel.Ops.put_and_close(env, handle, value)
        k.(handle, env)
      else
        watchers = Env.get_state(env, {@watcher_prefix, tag}, [])
        env = Env.put_state(env, {@watcher_prefix, tag}, [handle | watchers])
        k.(handle, env)
      end
    end
  end

  @impl Skuld.Comp.ITotalLinearHandler
  def handle({@get_op, tag}, env) do
    value = Env.get_state(env, {@cell_prefix, tag})
    {value, env}
  end

  @impl Skuld.Comp.ITotalLinearHandler
  def handle({@put_op, tag, value}, env) do
    owner = Env.get_state(env, {@owner_prefix, tag})
    current = FiberPool.current_fiber_id(env)

    env =
      case owner do
        nil ->
          Env.put_state(env, {@owner_prefix, tag}, current)

        ^current ->
          env

        _other ->
          raise "Cell tag #{inspect(tag)} is owned by fiber #{inspect(owner)}, " <>
                  "cannot write from fiber #{inspect(current)}"
      end

    old = Env.get_state(env, {@cell_prefix, tag})
    env = Env.put_state(env, {@cell_prefix, tag}, value)
    env = wake_watchers(env, tag, value)
    change = Skuld.Effects.State.Change.new(old, value)
    {change, env}
  end

  defp handle(args, env, k) do
    {value, env2} = handle(args, env)
    k.(value, env2)
  end

  defp wake_watchers(env, tag, value) do
    watchers = Env.get_state(env, {@watcher_prefix, tag}, [])

    if watchers == [] do
      env
    else
      env =
        Enum.reduce(watchers, env, fn handle, acc_env ->
          Channel.Ops.put_and_close(acc_env, handle, value)
        end)

      Env.put_state(env, {@watcher_prefix, tag}, [])
    end
  end
end
