# Port contract for common Ecto Repo operations.
#
# Provides a built-in set of defport declarations so that every domain
# using Port for DB operations doesn't need to redeclare insert/update/
# delete/get/all etc. with identical boilerplate.
#
# ## Usage
#
#     alias Skuld.Effects.Port.Repo
#
#     comp do
#       record <- Repo.EffectPort.insert!(changeset)
#       # ...
#     end
#
# ## Handler Installation
#
#     # Production — delegates to your Ecto Repo
#     defmodule MyApp.Repo.Port do
#       use Skuld.Effects.Port.Repo.Ecto, repo: MyApp.Repo
#     end
#
#     comp
#     |> Port.with_handler(%{Port.Repo => MyApp.Repo.Port})
#     |> Comp.run!()
#
#     # Test — in-memory executor with dispatch logging
#     comp
#     |> Port.with_handler(
#       %{Port.Repo => Port.Repo.Test},
#       log: true,
#       output: fn r, state -> {r, state.log} end
#     )
#     |> Throw.with_handler()
#     |> Comp.run!()
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo do
    @moduledoc """
    Port contract for common Ecto Repo operations.

    Provides `defport` declarations for the standard write and read operations
    from `Ecto.Repo`, so that domain code using `Port` for database access
    doesn't need to redeclare these with identical boilerplate.

    ## Write Operations

    Write operations return `{:ok, struct()} | {:error, Ecto.Changeset.t()}`
    and auto-generate bang variants (`insert!`, `update!`, `delete!`) that
    unwrap the success value or dispatch `Throw` on error.

    ## Bulk Operations

    `update_all/3` and `delete_all/1` follow Ecto's return convention of
    `{count, nil | list}`. No bang variants are generated for these.

    ## Read Operations

    Read operations follow Ecto's conventions: `get/2`, `get_by/2`, `one/1`
    return `nil` on not-found; `all/1` returns a list; `exists?/1` returns
    a boolean; `aggregate/3` returns a term.

    Bang read variants (`get!/2`, `get_by!/2`, `one!/1`) are provided as
    separate port operations that mirror Ecto's raise-on-not-found semantics.
    In the effectful context these dispatch `Throw` instead of raising.

    ## Example

        alias Skuld.Effects.Port.Repo

        use Skuld.Syntax

        defcomp create_user(attrs) do
          changeset = User.changeset(%User{}, attrs)
          user <- Repo.EffectPort.insert!(changeset)
          return(user)
        end

        defcomp find_user(id) do
          user <- Repo.EffectPort.get(User, id)
          return(user)
        end
    """

    use Skuld.Effects.Port.Contract

    # -----------------------------------------------------------------
    # Write Operations
    # -----------------------------------------------------------------

    @doc "Insert a new record from a changeset."
    defport insert(changeset :: Ecto.Changeset.t()) ::
              {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Update an existing record from a changeset."
    defport update(changeset :: Ecto.Changeset.t()) ::
              {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Delete a record."
    defport delete(record :: struct()) ::
              {:ok, struct()} | {:error, Ecto.Changeset.t()}

    # -----------------------------------------------------------------
    # Bulk Operations
    # -----------------------------------------------------------------

    @doc "Update all records matching a queryable."
    defport update_all(
              queryable :: Ecto.Queryable.t(),
              updates :: keyword(),
              opts :: keyword()
            ) :: {non_neg_integer(), nil | list()}

    @doc "Delete all records matching a queryable."
    defport delete_all(queryable :: Ecto.Queryable.t(), opts :: keyword()) ::
              {non_neg_integer(), nil | list()}

    # -----------------------------------------------------------------
    # Read Operations
    # -----------------------------------------------------------------

    @doc "Fetch a single record by primary key. Returns `nil` if not found."
    defport get(queryable :: Ecto.Queryable.t(), id :: term()) :: struct() | nil

    @doc """
    Fetch a single record by primary key, or dispatch Throw if not found.

    Mirrors `Ecto.Repo.get!/2` — in the effectful context this dispatches
    `Throw` with `{:not_found, queryable, id}` instead of raising.
    """
    defport get!(queryable :: Ecto.Queryable.t(), id :: term()) :: struct(), bang: false

    @doc "Fetch a single record by the given clauses. Returns `nil` if not found."
    defport get_by(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) ::
              struct() | nil

    @doc """
    Fetch a single record by the given clauses, or dispatch Throw if not found.

    Mirrors `Ecto.Repo.get_by!/2`.
    """
    defport get_by!(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) :: struct(),
      bang: false

    @doc "Fetch a single result from a query. Returns `nil` if no result."
    defport one(queryable :: Ecto.Queryable.t()) :: struct() | nil

    @doc """
    Fetch a single result from a query, or dispatch Throw if no result.

    Mirrors `Ecto.Repo.one!/1`.
    """
    defport one!(queryable :: Ecto.Queryable.t()) :: struct(), bang: false

    @doc "Fetch all records matching a queryable."
    defport all(queryable :: Ecto.Queryable.t()) :: list(struct())

    @doc "Check whether any record matching the queryable exists."
    defport exists?(queryable :: Ecto.Queryable.t()) :: boolean()

    @doc "Calculate an aggregate over the given field."
    defport aggregate(queryable :: Ecto.Queryable.t(), aggregate :: atom(), field :: atom()) ::
              term()
  end
end
