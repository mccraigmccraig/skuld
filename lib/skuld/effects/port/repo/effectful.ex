# Effectful contract for Repo operations.
#
# Generates effectful @callback declarations from the plain
# Repo.Contract, plus __port_operations__/0 and __port_effectful__?/0.
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.Effectful do
    @moduledoc """
    Effectful behaviour for `Skuld.Effects.Port.Repo.Contract`.

    Defines computation-returning callbacks for each Repo operation.
    Effectful implementations declare `@behaviour Skuld.Effects.Port.Repo.Effectful`.
    """

    require Skuld.Effects.Port.Repo.Contract

    use Skuld.Effects.Port.EffectfulContract,
      hex_port_contract: Skuld.Effects.Port.Repo.Contract
  end
end
