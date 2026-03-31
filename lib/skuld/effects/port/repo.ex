# Effectful dispatch facade for the Repo contract.
#
# ## Usage
#
#     alias Skuld.Effects.Port.Repo
#
#     comp do
#       {:ok, user} <- Repo.insert(changeset)
#       found <- Repo.get(User, user.id)
#       {user, found}
#     end
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo do
    @moduledoc """
    Effectful dispatch facade for `Skuld.Effects.Port.Repo.Contract`.

    Provides effectful caller functions, bang variants, and key helpers
    for the standard Ecto Repo operations.

    ## Usage

        alias Skuld.Effects.Port.Repo

        comp do
          user <- Repo.insert!(changeset)
          found <- Repo.get(User, user.id)
          {user, found}
        end
        |> Port.with_handler(%{Repo.Contract => MyApp.Repo.Ecto})
        |> Throw.with_handler()
        |> Comp.run!()
    """

    use Skuld.Effects.Port.Facade, contract: Skuld.Effects.Port.Repo.Contract
  end
end
