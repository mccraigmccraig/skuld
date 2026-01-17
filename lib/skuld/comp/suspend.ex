defmodule Skuld.Comp.Suspend do
  @moduledoc """
  Sentinel that bypasses leave-scope chain.

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
    def run(suspend, env), do: {suspend, env}

    def run!(%Skuld.Comp.Suspend{}) do
      raise "Computation suspended unexpectedly"
    end

    def sentinel?(_), do: true

    def get_resume(%Skuld.Comp.Suspend{resume: resume}), do: resume

    def with_resume(suspend, new_resume) do
      %Skuld.Comp.Suspend{suspend | resume: new_resume}
    end

    def serializable_payload(%Skuld.Comp.Suspend{value: value, data: nil}) do
      %{yielded: value}
    end

    def serializable_payload(%Skuld.Comp.Suspend{value: value, data: data}) do
      %{yielded: value, data: data}
    end
  end
end
