if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.ChangesetPersist do
    @moduledoc """
    Effect for persisting Ecto changesets to the database.

    Provides both single operations (working with changesets or ChangeEvents)
    and bulk operations (working with lists of changesets, maps, or ChangeEvents).

    ## Single Operations

    Accept either a raw changeset or a ChangeEvent:

        user <- ChangesetPersist.insert(changeset)
        user <- ChangesetPersist.insert(ChangeEvent.insert(changeset))

        user <- ChangesetPersist.update(changeset)
        user <- ChangesetPersist.upsert(changeset, conflict_target: :email)
        {:ok, _} <- ChangesetPersist.delete(user)

    ## Bulk Operations

    Accept lists of changesets, maps, or ChangeEvents.
    All elements MUST be for the same schema:

        {count, users} <- ChangesetPersist.insert_all(User, changesets, returning: true)
        {count, nil}   <- ChangesetPersist.update_all(User, changesets)
        {count, nil}   <- ChangesetPersist.delete_all(User, structs)

    ## Handlers

    Production (Ecto Repo):

        computation
        |> ChangesetPersist.Ecto.with_handler(MyApp.Repo)
        |> Comp.run!()

    Testing (records calls, returns stubs):

        {result, calls} =
          computation
          |> ChangesetPersist.Test.with_handler(fn op -> handle_op(op) end)
          |> Comp.run!()

    ## Error Handling

    Operations that fail (e.g., invalid changeset) will throw via the
    Throw effect. Use `Throw.with_handler()` to catch errors:

        comp do
          user <- ChangesetPersist.insert(changeset)
          return(user)
        catch
          {:invalid_changeset, cs} -> return({:error, cs})
        end
        |> ChangesetPersist.Ecto.with_handler(Repo)
        |> Throw.with_handler()
        |> Comp.run!()
    """

    import Skuld.Comp.DefOp

    alias Skuld.Comp
    alias Skuld.Comp.Types
    alias Skuld.Effects.ChangeEvent

    @sig __MODULE__

    @doc false
    def sig, do: @sig

    #############################################################################
    ## Operation Structs
    #############################################################################

    def_op(Insert, [:input, :opts])
    def_op(Update, [:input, :opts])
    def_op(Upsert, [:input, :opts])
    def_op(Delete, [:input, :opts])
    def_op(InsertAll, [:schema, :entries, :opts])
    def_op(UpdateAll, [:schema, :entries, :opts])
    def_op(UpsertAll, [:schema, :entries, :opts])
    def_op(DeleteAll, [:schema, :entries, :opts])

    #############################################################################
    ## Single Operations
    #############################################################################

    @doc """
    Insert a record from a changeset or ChangeEvent.

    Returns the inserted struct on success, throws on error.

    ## Example

        user <- ChangesetPersist.insert(User.changeset(attrs))
        user <- ChangesetPersist.insert(ChangeEvent.insert(changeset))
    """
    @spec insert(Ecto.Changeset.t() | ChangeEvent.t(), keyword()) :: Types.computation()
    def insert(input, opts \\ []) do
      Comp.effect(@sig, %Insert{input: input, opts: opts})
    end

    @doc """
    Update a record from a changeset or ChangeEvent.

    Returns the updated struct on success, throws on error.

    ## Example

        user <- ChangesetPersist.update(User.changeset(user, attrs))
    """
    @spec update(Ecto.Changeset.t() | ChangeEvent.t(), keyword()) :: Types.computation()
    def update(input, opts \\ []) do
      Comp.effect(@sig, %Update{input: input, opts: opts})
    end

    @doc """
    Insert or update a record (upsert) from a changeset or ChangeEvent.

    Returns the inserted/updated struct on success, throws on error.

    ## Example

        user <- ChangesetPersist.upsert(changeset, conflict_target: :email)
    """
    @spec upsert(Ecto.Changeset.t() | ChangeEvent.t(), keyword()) :: Types.computation()
    def upsert(input, opts \\ []) do
      Comp.effect(@sig, %Upsert{input: input, opts: opts})
    end

    @doc """
    Delete a record from a struct, changeset, or ChangeEvent.

    Returns `{:ok, struct}` on success, throws on error.

    ## Example

        {:ok, user} <- ChangesetPersist.delete(user)
        {:ok, user} <- ChangesetPersist.delete(ChangeEvent.delete(changeset))
    """
    @spec delete(struct() | Ecto.Changeset.t() | ChangeEvent.t(), keyword()) ::
            Types.computation()
    def delete(input, opts \\ []) do
      Comp.effect(@sig, %Delete{input: input, opts: opts})
    end

    #############################################################################
    ## Bulk Operations
    #############################################################################

    @doc """
    Insert multiple records.

    Accepts a list of changesets, maps, or ChangeEvents. All must be for
    the same schema.

    Returns `{count, nil | [struct]}` depending on `:returning` option.

    ## Example

        {count, users} <- ChangesetPersist.insert_all(User, changesets, returning: true)
        {count, nil} <- ChangesetPersist.insert_all(User, maps)
    """
    @spec insert_all(module(), [Ecto.Changeset.t() | map() | ChangeEvent.t()], keyword()) ::
            Types.computation()
    def insert_all(schema, entries, opts \\ []) do
      Comp.effect(@sig, %InsertAll{schema: schema, entries: entries, opts: opts})
    end

    @doc """
    Update multiple records.

    For changesets/ChangeEvents: applies each update individually (not truly bulk).
    For maps with `:query` option: uses Repo.update_all with the query.

    Returns `{count, nil | [struct]}`.

    ## Example

        # Update each changeset individually
        {count, users} <- ChangesetPersist.update_all(User, changesets, returning: true)

        # Bulk update via query
        {count, nil} <- ChangesetPersist.update_all(User, [], query: query, set: [active: false])
    """
    @spec update_all(module(), [Ecto.Changeset.t() | ChangeEvent.t()], keyword()) ::
            Types.computation()
    def update_all(schema, entries, opts \\ []) do
      Comp.effect(@sig, %UpdateAll{schema: schema, entries: entries, opts: opts})
    end

    @doc """
    Upsert multiple records.

    Returns `{count, nil | [struct]}`.

    ## Example

        {count, users} <- ChangesetPersist.upsert_all(User, changesets,
          conflict_target: :email,
          returning: true
        )
    """
    @spec upsert_all(module(), [Ecto.Changeset.t() | map() | ChangeEvent.t()], keyword()) ::
            Types.computation()
    def upsert_all(schema, entries, opts \\ []) do
      Comp.effect(@sig, %UpsertAll{schema: schema, entries: entries, opts: opts})
    end

    @doc """
    Delete multiple records.

    Accepts a list of structs, changesets, or ChangeEvents.

    Returns `{count, nil | [struct]}`.

    ## Example

        {count, nil} <- ChangesetPersist.delete_all(User, users)
    """
    @spec delete_all(module(), [struct() | Ecto.Changeset.t() | ChangeEvent.t()], keyword()) ::
            Types.computation()
    def delete_all(schema, entries, opts \\ []) do
      Comp.effect(@sig, %DeleteAll{schema: schema, entries: entries, opts: opts})
    end
  end
end
