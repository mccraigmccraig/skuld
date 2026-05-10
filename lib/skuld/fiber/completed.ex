defmodule Skuld.Fiber.Completed do
  @moduledoc false

  alias Skuld.Comp.Env

  @type t :: %__MODULE__{
          id: reference(),
          result: term(),
          env: Env.t()
        }

  defstruct [:id, :result, :env]
end
