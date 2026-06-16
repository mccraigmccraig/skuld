defmodule Skuld.Effects.FiberYield do
  @moduledoc false

  use Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.InternalSuspend

  @yield_op Module.concat(Skuld.Effects.Yield, Yield)

  def_op notify(value)

  @doc """
  Install a Yield handler that produces `InternalSuspend` with `FiberYield`
  payloads instead of `ExternalSuspend`, and a notify handler for
  fire-and-forget notifications.

  Use inside a FiberPool context so the scheduler can manage suspended
  fibers while other fibers run.

      computation
      |> FiberYield.with_handler()
      |> FiberPool.with_handler()
      |> Comp.run()
  """
  @spec with_handler(Comp.Types.computation()) :: Comp.Types.computation()
  def with_handler(computation) do
    computation
    |> Comp.with_handler(Skuld.Effects.Yield, &handle_yield/3)
    |> Comp.with_handler(__MODULE__, &handle_notify/3)
  end

  @doc false
  def handle_yield({@yield_op, value}, env, k) do
    resume = fn input, resume_env ->
      {result, final_env} = k.(input, resume_env)

      case result do
        %InternalSuspend{} -> {result, final_env}
        %Comp.ExternalSuspend{} -> {result, final_env}
        _ -> Comp.Env.run_leave_scope(final_env, result)
      end
    end

    suspend = InternalSuspend.fiber_yield(value, resume)
    {suspend, env}
  end

  @notify_op @__notify_op__

  @doc false
  def handle_notify({@notify_op, value}, env, k) do
    resume = fn _input, resume_env -> k.(nil, resume_env) end
    suspend = InternalSuspend.fiber_notify(value, resume)
    {suspend, env}
  end
end
