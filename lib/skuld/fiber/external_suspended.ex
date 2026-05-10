defmodule Skuld.Fiber.ExternalSuspended do
  @moduledoc false

  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @type t :: %__MODULE__{
          id: reference(),
          k: Types.k(),
          env: Env.t()
        }

  defstruct [:id, :k, :env]
end
