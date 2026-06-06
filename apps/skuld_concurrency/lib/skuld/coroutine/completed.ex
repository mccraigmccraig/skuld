defmodule Skuld.Coroutine.Completed do
  @moduledoc """
  Fiber that finished successfully.

  ## Env semantics

  `env` is the final environment snapshot — scope, accumulated state
  (Writer logs, State values, etc.) as they were when the computation
  returned. The scheduler extracts `env.state` into shared pool state.
  """

  alias Skuld.Comp.Env

  @type t :: %__MODULE__{
          id: term(),
          result: term(),
          env: Env.t()
        }

  defstruct [:id, :result, :env]
end
