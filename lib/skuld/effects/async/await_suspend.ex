defmodule Skuld.Effects.Async.AwaitSuspend do
  @moduledoc """
  Sentinel indicating computation is awaiting async completions.

  Unlike `%Suspend{}` (which needs external input from outside the scheduler),
  `%AwaitSuspend{}` is handled internally by the cooperative scheduler based
  on task/timer/computation completions.

  ## Difference from Suspend

  - `%Suspend{value: v}` - "I'm yielding `v` and need external input to continue"
  - `%AwaitSuspend{request: r}` - "I'm waiting for these async targets to complete"

  The scheduler handles `AwaitSuspend` internally by tracking the request,
  waiting for completion messages, and resuming when wake conditions are met.

  ## Example

      # Inside an await handler
      %AwaitSuspend{
        request: AwaitRequest.new([TaskTarget.new(task)], :all),
        resume: fn [result] -> k.(result, env) end
      }
  """

  alias Skuld.Effects.Async.AwaitRequest

  defstruct [:request, :resume]

  @type t :: %__MODULE__{
          request: AwaitRequest.t(),
          resume: (term() -> {term(), Skuld.Comp.Env.t()})
        }

  defimpl Skuld.Comp.ISentinel do
    alias Skuld.Comp.Env

    def run(await_suspend, env) do
      # Pass through transform_suspend so EffectLogger can track await suspensions
      transform = Env.get_transform_suspend(env)
      transform.(await_suspend, env)
    end

    def run!(%Skuld.Effects.Async.AwaitSuspend{}) do
      raise "Computation suspended on await - use Scheduler to run cooperative computations"
    end

    def sentinel?(_), do: true

    def get_resume(%Skuld.Effects.Async.AwaitSuspend{resume: resume}), do: resume

    def with_resume(await_suspend, new_resume) do
      %Skuld.Effects.Async.AwaitSuspend{await_suspend | resume: new_resume}
    end

    def serializable_payload(%Skuld.Effects.Async.AwaitSuspend{request: request}) do
      # Serialize the request info without the resume function
      %{
        await_request: %{
          id: inspect(request.id),
          mode: request.mode,
          target_count: length(request.targets),
          target_types: Enum.map(request.targets, &target_type/1)
        }
      }
    end

    defp target_type(%Skuld.Effects.Async.AwaitRequest.TaskTarget{}), do: :task
    defp target_type(%Skuld.Effects.Async.AwaitRequest.TimerTarget{}), do: :timer

    defp target_type(%Skuld.Effects.Async.AwaitRequest.ComputationTarget{}),
      do: :computation
  end
end
