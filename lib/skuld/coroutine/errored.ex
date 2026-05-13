defmodule Skuld.Coroutine.Errored do
  @moduledoc """
  Fiber that terminated with an error.

  ## Env semantics

  `env` is the environment at error time — scope and state as they were
  when the error occurred. The scheduler extracts `env.state` into shared
  pool state. Scoped effects have already run their leave_scope cleanup
  (errors propagate through the leave_scope chain).
  """

  alias Skuld.Comp.Env

  @type t :: %__MODULE__{
          id: reference(),
          error: term(),
          env: Env.t()
        }

  defstruct [:id, :error, :env]
end
