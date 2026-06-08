# Effectful contract for Repo operations.
#
# Generates effectful @callback declarations from the plain
# Repo.Contract, plus __callbacks__/0 and __port_effectful__?/0.
#
defmodule Skuld.Repo.Effectful do
  @moduledoc """
  Effectful behaviour for `Skuld.Repo.Contract`.

  Defines computation-returning callbacks for each Repo operation.
  Effectful implementations declare `@behaviour Skuld.Repo.Effectful`.
  """

  require Skuld.Repo.Contract

  use Skuld.Adapter.EffectfulContract,
    double_down_contract: Skuld.Repo.Contract
end
