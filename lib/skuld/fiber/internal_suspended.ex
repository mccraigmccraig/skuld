defmodule Skuld.Fiber.InternalSuspended do
  @moduledoc false

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
