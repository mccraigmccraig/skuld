defmodule Skuld.Fiber.Cancelled do
  @moduledoc false

  alias Skuld.Comp.Env

  @type t :: %__MODULE__{
          id: reference(),
          reason: term(),
          env: Env.t()
        }

  defstruct [:id, :reason, :env]
end
