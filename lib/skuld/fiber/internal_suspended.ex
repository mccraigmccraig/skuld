defmodule Skuld.Fiber.InternalSuspended do
  @moduledoc """
  Fiber suspended with an internal scheduler dependency (channel, batch, await).

  ## Env semantics

  `env.state` is *stale* — the scheduler extracts it into the shared pool
  state at suspension time. On resume, the scheduler injects fresh shared
  state from the pool, so `env.state` is overwritten before the continuation
  runs. The env is stored in full so `cancel/2` has access to `leave_scope`
  and any stale-but-useful state for cleanup (e.g. Writer logs).
  """

  alias Skuld.Comp.Env
  alias Skuld.Comp.InternalSuspend
  alias Skuld.Comp.Types

  @type t :: %__MODULE__{
          id: reference(),
          k: Types.k(),
          suspend: InternalSuspend.t(),
          env: Env.t()
        }

  defstruct [:id, :k, :suspend, :env]
end
