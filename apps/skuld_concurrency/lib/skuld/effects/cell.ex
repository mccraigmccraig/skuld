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
  alias Skuld.Effects.FiberPool

  @cell_prefix :cell
  @owner_prefix :cell_owner

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
    new_env = Env.put_state(env, {@cell_prefix, tag}, value)
    change = Skuld.Effects.State.Change.new(old, value)
    {change, new_env}
  end

  defp handle(args, env, k) do
    {value, env2} = handle(args, env)
    k.(value, env2)
  end
end
