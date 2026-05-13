defmodule Skuld.Coroutine.Pending do
  @moduledoc """
  Fiber waiting to be run for the first time.

  ## Env semantics

  `env` holds the initial scope (handlers, leave_scope, transform_suspend)
  plus the state at creation time. Before the fiber runs, the scheduler
  injects fresh shared state into `env.state` — the stored state is
  overwritten and never used directly. The env is kept in full so `cancel/2`
  can invoke `leave_scope` for cleanup even before execution.
  """

  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @type t :: %__MODULE__{
          id: reference(),
          computation: Types.computation(),
          env: Env.t()
        }

  defstruct [:id, :computation, :env]
end
