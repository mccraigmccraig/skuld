defmodule Skuld.Coroutine.Error do
  @moduledoc """
  Canonical error representation for fiber failures.

  Normalizes all error paths — Elixir exceptions (raise/rescue),
  Elixir throws and exits, Skuld Throw.throw, cancellation, and
  BEAM task crashes — into a single struct. Replaces the ad-hoc
  tuple conventions that previously required multi-clause unwrapping.
  """

  @type type :: :exception | :throw | :exit | :cancelled

  @type t :: %__MODULE__{
          type: type(),
          error: term(),
          stacktrace: list() | nil
        }

  @derive Jason.Encoder
  defstruct [:type, :error, :stacktrace]
end
