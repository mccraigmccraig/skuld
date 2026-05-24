defmodule Skuld.Coroutine.ForeignSuspended do
  @moduledoc """
  Fiber state when a single fiber suspends on a foreign resource.

  The FiberPool scheduler collects all `ForeignSuspended` fibers, extracts
  their individual `ForeignSuspend` values, and bundles them into a
  `Coroutine.ForeignSuspensions` aggregate to return to the caller.
  """

  alias Skuld.Comp.Env
  alias Skuld.Comp.ForeignSuspend

  @type t :: %__MODULE__{
          id: term(),
          suspend: ForeignSuspend.t(),
          env: Env.t()
        }

  defstruct [:id, :suspend, :env]
end
