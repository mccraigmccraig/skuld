defmodule Skuld.Coroutine.ForeignSuspensions do
  @moduledoc """
  Aggregate of all pending foreign suspensions, returned to the caller
  (e.g., the Hologram JS runtime) when the FiberPool scheduler exhausts
  internal work.

  The caller extracts the individual `ForeignSuspend` values from the
  `:suspensions` list, resolves them via the foreign platform's event loop,
  and resumes the computation by calling `Coroutine.call/2` with a map of
  `%{suspend_id => resolved_value}`.

  The `:resume` field is a closure created by the FiberPool scheduler that
  captures the `FiberPoolState` and scheduler loop. It takes the resolved
  map, wakes all resolved fibers at once by enqueuing them on the run queue,
  and returns the next Coroutine state.

  ## Fields

  - `id` — identifier for this aggregate
  - `suspensions` — the list of `ForeignSuspend` values to resolve
  - `env` — the computation environment
  - `resume` — closure `(%{id => value}) -> Coroutine.t()` that batch-wakes fibers
  """

  alias Skuld.Comp.Env
  alias Skuld.Comp.ForeignSuspend

  @type t :: %__MODULE__{
          id: term(),
          suspensions: [ForeignSuspend.t()],
          env: Env.t(),
          resume: (map() -> t())
        }

  defstruct [:id, :suspensions, :env, :resume]

  defimpl Skuld.Comp.ISentinel do
    def run(suspensions, env) do
      {suspensions, env}
    end

    def run!(%Skuld.Coroutine.ForeignSuspensions{}) do
      raise "Computation suspended on foreign resources — must be handled by a foreign scheduler"
    end

    def sentinel?(_), do: true
    def suspend?(_), do: true
    def error?(_), do: false

    def serializable_payload(%Skuld.Coroutine.ForeignSuspensions{}) do
      raise "ForeignSuspensions cannot be serialized — payloads are opaque foreign-platform handles"
    end
  end
end
