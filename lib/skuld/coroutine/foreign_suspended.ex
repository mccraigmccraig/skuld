defmodule Skuld.Coroutine.ForeignSuspended do
  @moduledoc """
  Fiber state when the scheduler has bundled all foreign suspensions from the
  last run. Also serves as a sentinel returned to the caller via `ISentinel.run`.

  The caller (e.g., the Hologram JS runtime) extracts the individual
  `ForeignSuspend` values from the `:suspensions` list, resolves them via the
  foreign platform's event loop, and resumes each fiber with the result.
  """

  alias Skuld.Comp.Env
  alias Skuld.Comp.ForeignSuspend

  @type t :: %__MODULE__{
          id: term(),
          suspensions: [ForeignSuspend.t()],
          env: Env.t()
        }

  defstruct [:id, :suspensions, :env]

  defimpl Skuld.Comp.ISentinel do
    def run(suspensions, env) do
      {suspensions, env}
    end

    def run!(%Skuld.Coroutine.ForeignSuspended{}) do
      raise "Computation suspended on foreign resources — must be handled by a foreign scheduler"
    end

    def sentinel?(_), do: true
    def suspend?(_), do: true
    def error?(_), do: false

    def serializable_payload(%Skuld.Coroutine.ForeignSuspended{}) do
      raise "ForeignSuspended cannot be serialized — payloads are opaque foreign-platform handles"
    end
  end
end
