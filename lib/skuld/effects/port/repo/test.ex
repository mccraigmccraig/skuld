# Deprecated — use Skuld.Effects.Port.Repo.Stub instead.
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.Test do
    @moduledoc """
    Deprecated. Use `Skuld.Effects.Port.Repo.Stub` instead.

    This module is a backwards-compatibility alias. It delegates to
    `Repo.Stub` which wraps `DoubleDown.Repo.Stub`.
    """

    @doc """
    Create a new Stub handler function.

    Deprecated — use `Repo.Stub.new/1` instead.
    """
    @deprecated "Use Skuld.Effects.Port.Repo.Stub.new/1 instead"
    defdelegate new(opts \\ []), to: Skuld.Effects.Port.Repo.Stub
  end
end
