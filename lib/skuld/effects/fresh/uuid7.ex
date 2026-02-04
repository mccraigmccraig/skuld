# Production v7 UUID handler for Fresh effect.
#
# Generates time-ordered UUIDs using UUID v7 (RFC 9562). These UUIDs:
# - Are time-ordered (lexically sortable by creation time)
# - Have excellent database index locality
# - Are suitable for distributed systems
#
# ## Example
#
#     comp do
#       id <- Fresh.fresh_uuid()
#       return(id)
#     end
#     |> Fresh.UUID7.with_handler()
#     |> Comp.run!()
#     #=> "01945a3b-7c9d-7000-8000-..."  # v7 UUID
defmodule Skuld.Effects.Fresh.UUID7 do
  @moduledoc false

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  alias Skuld.Comp
  alias Skuld.Effects.Fresh.FreshUUID

  @sig Skuld.Effects.Fresh

  @doc """
  Install a v7 UUID handler for production use.

  Generates time-ordered UUIDs using UUID v7 (RFC 9562).

  ## Example

      comp do
        id <- Fresh.fresh_uuid()
        return(id)
      end
      |> Fresh.UUID7.with_handler()
      |> Comp.run!()
      #=> "01945a3b-7c9d-7000-8000-..."  # v7 UUID
  """
  @spec with_handler(Comp.Types.computation()) :: Comp.Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, @sig, &handle/3)
  end

  @impl Skuld.Comp.IInstall
  def __handle__(comp, _config), do: with_handler(comp)

  @impl Skuld.Comp.IHandle
  def handle(%FreshUUID{}, env, k) do
    uuid = Uniq.UUID.uuid7()
    k.(uuid, env)
  end
end
