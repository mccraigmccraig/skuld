defmodule Skuld.Coroutine.Cancelled do
  @moduledoc """
  Fiber that was cancelled before completion.

  ## Env semantics

  `env` is the environment after `leave_scope` cleanup ran. It may be
  `nil` if the fiber was cancelled from `Pending` (no scopes entered yet).
  For fibres cancelled from a suspended state, `env` reflects the state
  after all scoped cleanup handlers have executed.
  """

  alias Skuld.Comp.Env

  @type t :: %__MODULE__{
          id: term(),
          reason: term(),
          env: Env.t() | nil
        }

  defstruct [:id, :reason, :env]
end
