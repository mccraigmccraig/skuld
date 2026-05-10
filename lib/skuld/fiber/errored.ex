defmodule Skuld.Fiber.Errored do
  @moduledoc false

  alias Skuld.Comp.Env

  @type t :: %__MODULE__{
          id: reference(),
          error: term(),
          env: Env.t()
        }

  defstruct [:id, :error, :env]
end
