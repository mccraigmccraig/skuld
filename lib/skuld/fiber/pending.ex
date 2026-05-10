defmodule Skuld.Fiber.Pending do
  @moduledoc false

  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @type t :: %__MODULE__{
          id: reference(),
          computation: Types.computation(),
          env: Env.t()
        }

  defstruct [:id, :computation, :env]
end
