defmodule Skuld.Effects.FiberYield do
  @moduledoc false

  alias Skuld.Comp
  alias Skuld.Comp.InternalSuspend

  @yield_op Module.concat(Skuld.Effects.Yield, Yield)

  @doc """
  Install a Yield handler that produces `InternalSuspend` with `FiberYield`
  payloads instead of `ExternalSuspend`. Use inside a FiberPool context so
  the scheduler can manage the suspended fiber while other fibers run.

      computation
      |> FiberYield.with_handler()
      |> FiberPool.with_handler()
      |> Comp.run()
  """
  @spec with_handler(Comp.Types.computation()) :: Comp.Types.computation()
  def with_handler(computation) do
    Comp.with_handler(computation, Skuld.Effects.Yield, &handle/3)
  end

  @doc false
  def handle({@yield_op, value}, env, k) do
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
end
