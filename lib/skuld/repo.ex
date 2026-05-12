# Effectful dispatch facade for the Repo contract.
#
# ## Usage
#
#     alias Skuld.Repo
#
#     comp do
#       {:ok, user} <- Repo.insert(changeset)
#       found <- Repo.get(User, user.id)
#       {user, found}
#     end
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Repo do
    @moduledoc """
    Effectful dispatch facade for `Skuld.Repo.Effectful`.

    Provides effectful caller functions, bang variants, and key helpers
    for the standard Ecto Repo operations.

    ## Usage

        alias Skuld.Repo

        comp do
          user <- Repo.insert!(changeset)
          found <- Repo.get(User, user.id)
          {user, found}
        end
        |> Port.with_handler(%{Repo.Effectful => MyApp.Repo.Ecto})
        |> Throw.with_handler()
        |> Comp.run!()
    """

    use Skuld.Effects.Port.Facade, contract: Skuld.Repo.Effectful
  end
end
