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
defmodule Skuld.Repo do
  @moduledoc """
  Effectful dispatch facade for `Skuld.Repo.Effectful`.

  Part of the `skuld_repo` package, which provides Ecto Repo integration
  with InMemory (closed-world store), Ecto adapter, and Stub (stateless
  test double). See the
  [architecture guide](https://hexdocs.pm/skuld/architecture.html)
  for how this fits into the Skuld ecosystem.

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

  use Skuld.Effects.Port.EffectfulFacade, contract: Skuld.Repo.Effectful
end
