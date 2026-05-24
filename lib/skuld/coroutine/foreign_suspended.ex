defmodule Skuld.Coroutine.ForeignSuspended do
  @moduledoc """
  Fiber state returned when the scheduler has processed all internal work
  and bundles all pending foreign (platform-specific) suspensions together.

  The `:suspends` list contains one or more `Comp.ForeignSuspend` values —
  one per fiber that suspended on a foreign resource. The caller (e.g., the
  Hologram JS runtime) extracts the opaque `payload` from each, resolves
  them via the foreign platform's event loop, and resumes each fiber with
  the result via `Coroutine.run/2`.

  No separate `ForeignSuspensions` aggregate is needed — the FiberPool
  scheduler bundles foreign suspends into this state when the run queue
  and internal suspensions are exhausted.
  """

  alias Skuld.Comp.Env
  alias Skuld.Comp.ForeignSuspend

  @type t :: %__MODULE__{
          id: term(),
          suspends: [ForeignSuspend.t()],
          env: Env.t()
        }

  defstruct [:id, :suspends, :env]
end
