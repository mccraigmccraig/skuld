defmodule Skuld.Fiber.ExternalSuspended do
  @moduledoc """
  Fiber suspended for an external caller (e.g. Yield).

  ## Env semantics

  `k` closes over the env at suspension time — resuming ignores `env`
  entirely. `env` is stored solely for `cancel/2`, which invokes
  `leave_scope` to run scoped-effect cleanup. State in `env` is stale
  (the scheduler extracted it at suspension) but leave_scope handlers
  may still read it during teardown.
  """

  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @type t :: %__MODULE__{
          id: reference(),
          k: Types.k(),
          env: Env.t()
        }

  defstruct [:id, :k, :env]
end
