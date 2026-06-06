# Port contract for common Ecto Repo operations.
#
# Mirrors DoubleDown.Repo's defcallback declarations so that skuld's
# effectful Repo surface covers the same operations available through
# plain DoubleDown dispatch.
#
# ## Usage
#
#     alias Skuld.Repo
#
#     comp do
#       {:ok, record} <- Repo.insert(changeset)
#       # ...
#     end
#
# ## Handler Installation
#
#     # Production — delegates to your Ecto Repo
#     defmodule MyApp.Repo.Port do
#       use Skuld.Repo.Ecto, repo: MyApp.Repo
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
#     |> Comp.run!()
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Repo.Contract do
    @moduledoc """
    Port contract for common Ecto Repo operations.

    Mirrors `DoubleDown.Repo`'s `defcallback` declarations so that skuld's
    effectful Repo surface covers the same operations available through
    plain DoubleDown dispatch. This enables the upgrade/downgrade path:
    code using `DoubleDown.Repo` via `ContractFacade` can switch to skuld's
    effectful dispatch (or back) without changing the contract.

    ## Write Operations

    Write operations return `{:ok, struct()} | {:error, Ecto.Changeset.t()}`.
    Opts-accepting variants (`insert/2`, `update/2`, `delete/2`) are provided
    for use in `Ecto.Multi` callbacks and similar contexts.

    Bang write variants (`insert!/1,2`, `update!/1,2`, `delete!/1,2`) are
    explicit operations that raise on failure, mirroring `Ecto.Repo`.

    ## Upsert Operations

    `insert_or_update/1,2` and their bang variants delegate to insert or
    update based on whether the changeset's data has `:loaded` state.

    ## Bulk Operations

    `insert_all/3`, `update_all/3` and `delete_all/2` follow Ecto's return
    convention of `{count, nil | list}`.

    ## Read Operations

    Read operations follow Ecto's conventions: `get/2`, `get_by/2`, `one/1`
    return `nil` on not-found; `all/1` returns a list; `exists?/1` returns
    a boolean; `aggregate/3` returns a term.

    Bang read variants (`get!/2`, `get_by!/2`, `one!/1`) are provided as
    separate operations that mirror Ecto's raise-on-not-found semantics.
    In the effectful context these dispatch `Throw` instead of raising.

    ## Transaction Operations

    Transaction operations (`transact`, `transaction`, `rollback`,
    `in_transaction?`) are deliberately omitted from the Repo contract.
    In skuld, transaction coordination is handled by the `Transaction`
    effect (`Skuld.Effects.Transaction`), which provides env state
    rollback, nested savepoints, and optional DB transaction wrapping.

    Similarly, `Ecto.Multi` is not supported — it is a limited
    sequencing mechanism that is superseded by skuld's effect-based
    computation composition (`comp do ... end`).
    """

    use DoubleDown.Contract

    # -----------------------------------------------------------------
    # Write Operations
    # -----------------------------------------------------------------

    @doc "Insert a new record from a changeset or struct."
    defcallback insert(struct_or_changeset :: Ecto.Changeset.t() | struct()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Insert a new record from a changeset or struct with options."
    defcallback insert(struct_or_changeset :: Ecto.Changeset.t() | struct(), opts :: keyword()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Update an existing record from a changeset."
    defcallback update(changeset :: Ecto.Changeset.t()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Update an existing record from a changeset with options."
    defcallback update(changeset :: Ecto.Changeset.t(), opts :: keyword()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Delete a record or changeset."
    defcallback delete(struct_or_changeset :: struct() | Ecto.Changeset.t()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Delete a record or changeset with options."
    defcallback delete(struct_or_changeset :: struct() | Ecto.Changeset.t(), opts :: keyword()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    # -----------------------------------------------------------------
    # Bang Write Operations
    # -----------------------------------------------------------------

    @doc "Insert a new record, raising on failure. Mirrors `Ecto.Repo.insert!/2`."
    defcallback insert!(struct_or_changeset :: Ecto.Changeset.t() | struct()) :: struct()

    @doc "Insert a new record with options, raising on failure."
    defcallback insert!(struct_or_changeset :: Ecto.Changeset.t() | struct(), opts :: keyword()) ::
                  struct()

    @doc "Update an existing record, raising on failure. Mirrors `Ecto.Repo.update!/2`."
    defcallback update!(changeset :: Ecto.Changeset.t()) :: struct()

    @doc "Update an existing record with options, raising on failure."
    defcallback update!(changeset :: Ecto.Changeset.t(), opts :: keyword()) :: struct()

    @doc "Delete a record or changeset, raising on failure. Mirrors `Ecto.Repo.delete!/2`."
    defcallback delete!(struct_or_changeset :: struct() | Ecto.Changeset.t()) :: struct()

    @doc "Delete a record or changeset with options, raising on failure."
    defcallback delete!(struct_or_changeset :: struct() | Ecto.Changeset.t(), opts :: keyword()) ::
                  struct()

    # -----------------------------------------------------------------
    # Upsert Operations
    # -----------------------------------------------------------------

    @doc "Insert or update a record depending on whether it has been loaded."
    defcallback insert_or_update(changeset :: Ecto.Changeset.t()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Insert or update a record with options."
    defcallback insert_or_update(changeset :: Ecto.Changeset.t(), opts :: keyword()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Insert or update a record, raising on failure."
    defcallback insert_or_update!(changeset :: Ecto.Changeset.t()) :: struct()

    @doc "Insert or update a record with options, raising on failure."
    defcallback insert_or_update!(changeset :: Ecto.Changeset.t(), opts :: keyword()) :: struct()

    # -----------------------------------------------------------------
    # Raw SQL Operations
    # -----------------------------------------------------------------

    @doc "Execute a raw SQL query. Returns `{:ok, result} | {:error, term()}`."
    defcallback query(sql :: String.t()) :: {:ok, term()} | {:error, term()}

    @doc "Execute a raw SQL query with parameters."
    defcallback query(sql :: String.t(), params :: list()) :: {:ok, term()} | {:error, term()}

    @doc "Execute a raw SQL query with parameters and options."
    defcallback query(sql :: String.t(), params :: list(), opts :: keyword()) ::
                  {:ok, term()} | {:error, term()}

    @doc "Execute a raw SQL query, raising on error."
    defcallback query!(sql :: String.t()) :: term()

    @doc "Execute a raw SQL query with parameters, raising on error."
    defcallback query!(sql :: String.t(), params :: list()) :: term()

    @doc "Execute a raw SQL query with parameters and options, raising on error."
    defcallback query!(sql :: String.t(), params :: list(), opts :: keyword()) :: term()

    # -----------------------------------------------------------------
    # Bulk Operations
    # -----------------------------------------------------------------

    @doc "Insert all entries into a schema or source at once."
    defcallback insert_all(
                  source :: Ecto.Queryable.t() | binary(),
                  entries :: [map() | keyword()],
                  opts :: keyword()
                ) :: {non_neg_integer(), nil | list()}

    @doc "Update all records matching a queryable."
    defcallback update_all(
                  queryable :: Ecto.Queryable.t(),
                  updates :: keyword(),
                  opts :: keyword()
                ) :: {non_neg_integer(), nil | list()}

    @doc "Delete all records matching a queryable."
    defcallback delete_all(queryable :: Ecto.Queryable.t(), opts :: keyword()) ::
                  {non_neg_integer(), nil | list()}

    # -----------------------------------------------------------------
    # Read Operations
    # -----------------------------------------------------------------

    @doc "Fetch a single record by primary key. Returns `nil` if not found."
    defcallback get(queryable :: Ecto.Queryable.t(), id :: term()) :: struct() | nil

    @doc "Fetch a single record by primary key with options."
    defcallback get(queryable :: Ecto.Queryable.t(), id :: term(), opts :: keyword()) ::
                  struct() | nil

    @doc """
    Fetch a single record by primary key, or dispatch Throw if not found.

    Mirrors `Ecto.Repo.get!/2` — in the effectful context this dispatches
    `Throw` instead of raising.
    """
    defcallback get!(queryable :: Ecto.Queryable.t(), id :: term()) :: struct()

    @doc "Fetch a single record by primary key with options, or dispatch Throw."
    defcallback get!(queryable :: Ecto.Queryable.t(), id :: term(), opts :: keyword()) :: struct()

    @doc "Fetch a single record by the given clauses. Returns `nil` if not found."
    defcallback get_by(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) ::
                  struct() | nil

    @doc "Fetch a single record by the given clauses with options."
    defcallback get_by(
                  queryable :: Ecto.Queryable.t(),
                  clauses :: keyword() | map(),
                  opts :: keyword()
                ) :: struct() | nil

    @doc """
    Fetch a single record by the given clauses, or dispatch Throw if not found.

    Mirrors `Ecto.Repo.get_by!/2`.
    """
    defcallback get_by!(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) :: struct()

    @doc "Fetch a single record by the given clauses with options, or dispatch Throw."
    defcallback get_by!(
                  queryable :: Ecto.Queryable.t(),
                  clauses :: keyword() | map(),
                  opts :: keyword()
                ) :: struct()

    @doc "Fetch a single result from a query. Returns `nil` if no result."
    defcallback one(queryable :: Ecto.Queryable.t()) :: struct() | nil

    @doc "Fetch a single result from a query with options."
    defcallback one(queryable :: Ecto.Queryable.t(), opts :: keyword()) :: struct() | nil

    @doc """
    Fetch a single result from a query, or dispatch Throw if no result.

    Mirrors `Ecto.Repo.one!/1`.
    """
    defcallback one!(queryable :: Ecto.Queryable.t()) :: struct()

    @doc "Fetch a single result from a query with options, or dispatch Throw."
    defcallback one!(queryable :: Ecto.Queryable.t(), opts :: keyword()) :: struct()

    @doc "Fetch all records matching a queryable."
    defcallback all(queryable :: Ecto.Queryable.t()) :: list(struct())

    @doc "Fetch all records matching a queryable with options."
    defcallback all(queryable :: Ecto.Queryable.t(), opts :: keyword()) :: list(struct())

    @doc "Check whether any record matching the queryable exists."
    defcallback exists?(queryable :: Ecto.Queryable.t()) :: boolean()

    @doc "Check whether any record matching the queryable exists, with options."
    defcallback exists?(queryable :: Ecto.Queryable.t(), opts :: keyword()) :: boolean()

    @doc "Calculate an aggregate over the given field."
    defcallback aggregate(queryable :: Ecto.Queryable.t(), aggregate :: atom(), field :: atom()) ::
                  term()

    @doc "Calculate an aggregate over the given field with options."
    defcallback aggregate(
                  queryable :: Ecto.Queryable.t(),
                  aggregate :: atom(),
                  field :: atom(),
                  opts :: keyword()
                ) :: term()

    @doc "Fetch all records matching the given clauses."
    defcallback all_by(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) ::
                  list(struct())

    @doc "Fetch all records matching the given clauses with options."
    defcallback all_by(
                  queryable :: Ecto.Queryable.t(),
                  clauses :: keyword() | map(),
                  opts :: keyword()
                ) :: list(struct())

    # -----------------------------------------------------------------
    # Stream Operations
    # -----------------------------------------------------------------

    @doc "Return a lazy enumerable that emits all records matching a queryable."
    defcallback stream(queryable :: Ecto.Queryable.t()) :: Enum.t()

    @doc "Return a lazy enumerable with options."
    defcallback stream(queryable :: Ecto.Queryable.t(), opts :: keyword()) :: Enum.t()

    # -----------------------------------------------------------------
    # Reload Operations
    # -----------------------------------------------------------------

    @doc "Reload a struct or list of structs from the data store."
    defcallback reload(struct_or_structs :: struct() | list(struct())) ::
                  struct() | nil | list(struct() | nil)

    @doc "Reload a struct or list of structs with options."
    defcallback reload(struct_or_structs :: struct() | list(struct()), opts :: keyword()) ::
                  struct() | nil | list(struct() | nil)

    @doc "Reload a struct or list of structs, raising if any are not found."
    defcallback reload!(struct_or_structs :: struct() | list(struct())) ::
                  struct() | list(struct())

    @doc "Reload a struct or list of structs with options, raising if not found."
    defcallback reload!(struct_or_structs :: struct() | list(struct()), opts :: keyword()) ::
                  struct() | list(struct())

    # -----------------------------------------------------------------
    # Preload Operations
    # -----------------------------------------------------------------

    @doc "Preload associations on a struct, list of structs, or nil."
    defcallback preload(
                  structs_or_struct_or_nil :: list(struct()) | struct() | nil,
                  preloads :: term()
                ) :: list(struct()) | struct() | nil

    @doc "Preload associations with options."
    defcallback preload(
                  structs_or_struct_or_nil :: list(struct()) | struct() | nil,
                  preloads :: term(),
                  opts :: keyword()
                ) :: list(struct()) | struct() | nil

    # -----------------------------------------------------------------
    # Load Operations
    # -----------------------------------------------------------------

    @doc "Load a schema struct or map from raw data. Mirrors `Ecto.Repo.load/2`."
    defcallback load(
                  schema_or_map :: module() | map(),
                  data :: map() | keyword() | {list(), list()}
                ) :: struct() | map()
  end
end
