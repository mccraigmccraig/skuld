defmodule Skuld.Comp.ExternalSuspend do
  @moduledoc """
  External suspension for yielding to code outside Skuld's env threading.

  Unlike `InternalSuspend` (which receives env at resume time), this suspension
  closes over the env at suspension point. Use this when:
  - Yielding values to external code that doesn't understand Skuld's env
  - The Yield effect's coroutine-style suspension
  - Any suspension where the caller will provide a value but not an updated env

  ## Resume Signature

  `resume :: (val) -> {result, env}` - closes over env from suspension point

  The `:data` field holds decorations added by scoped effects via `transform_suspend`.
  Default is `nil` to distinguish "no decorations" from "empty decorations map".
  """

  @type t :: %__MODULE__{
          value: term(),
          resume: (term() -> {term(), Skuld.Comp.Env.t()}) | nil,
          data: map() | nil
        }

  defstruct [:value, :resume, :data]
  # resume :: (input -> {result, env})

  defimpl Skuld.Comp.ISentinel do
    alias Skuld.Comp.Env

    def run(suspend, env) do
      transform = Env.get_transform_suspend(env)
      transform.(suspend, env)
    end

    def run!(%Skuld.Comp.ExternalSuspend{}) do
      raise "Computation suspended unexpectedly"
    end

    def sentinel?(_), do: true
    def suspend?(_), do: true
    def error?(_), do: false

    def get_resume(%Skuld.Comp.ExternalSuspend{resume: resume}), do: resume

    def with_resume(suspend, new_resume) do
      %Skuld.Comp.ExternalSuspend{suspend | resume: new_resume}
    end

    def serializable_payload(%Skuld.Comp.ExternalSuspend{value: value, data: nil}) do
      %{yielded: value}
    end

    def serializable_payload(%Skuld.Comp.ExternalSuspend{value: value, data: data}) do
      %{yielded: value, data: data}
    end
  end
end
