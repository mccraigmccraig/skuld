defmodule Skuld.Comp.ForeignSuspend do
  @moduledoc """
  Suspension for external/foreign resources (e.g., JavaScript Promises).

  Like `InternalSuspend`, the `resume` function receives the env at resume
  time — `(val, env) -> {result, env}`. This allows the scheduler to inject
  updated shared state into the env before the continuation runs.

  The `:payload` field is an opaque handle for the foreign platform to
  resolve the suspension. Skuld treats it as a black box — it never inspects
  or uses it directly. The Hologram JS runtime stores a Promise ref here;
  other platforms would store whatever their event loop needs.

  ## Fields

  - `resume` — continuation, receives `(val, env) -> {result, env}`
  - `payload` — opaque handle for the foreign platform
  """

  alias Skuld.Comp.Env

  @type t :: %__MODULE__{
          resume: (term(), Env.t() -> {term(), Env.t()}),
          payload: term()
        }

  defstruct [:resume, :payload]

  defimpl Skuld.Comp.ISentinel do
    def run(suspend, env) do
      {suspend, env}
    end

    def run!(%Skuld.Comp.ForeignSuspend{}) do
      raise "Computation suspended on a foreign resource — must be handled by a scheduler with foreign support"
    end

    def sentinel?(_), do: true
    def suspend?(_), do: true
    def error?(_), do: false

    def serializable_payload(%Skuld.Comp.ForeignSuspend{}) do
      raise "ForeignSuspend cannot be serialized — its payload is an opaque foreign-platform handle"
    end
  end
end
