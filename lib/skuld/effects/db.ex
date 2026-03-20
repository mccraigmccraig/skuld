if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.DB do
    @moduledoc """
    Unified effect for database writes and transactions.

    Provides single operations (working with changesets or ChangeEvents),
    bulk operations (working with lists of changesets, maps, or ChangeEvents),
    and transaction management.

    ## Single Operations

    Accept either a raw changeset or a ChangeEvent:

        user <- DB.insert(changeset)
        user <- DB.insert(ChangeEvent.insert(changeset))

        user <- DB.update(changeset)
        user <- DB.upsert(changeset, conflict_target: :email)
        {:ok, _} <- DB.delete(user)

    ## Bulk Operations

    Accept lists of changesets, maps, or ChangeEvents.
    All elements MUST be for the same schema:

        {count, users} <- DB.insert_all(User, changesets, returning: true)
        {count, nil}   <- DB.update_all(User, changesets)
        {count, nil}   <- DB.delete_all(User, structs)

    ## Transactions

        result <- DB.transact(comp do
          user <- DB.insert(changeset)
          order <- DB.insert(order_changeset)
          return({user, order})
        end)

    ## Handlers

    Production (Ecto Repo):

        computation
        |> DB.Ecto.with_handler(MyApp.Repo)
        |> Comp.run!()

    Testing (records calls, returns stubs):

        {result, calls} =
          computation
          |> DB.Test.with_handler(fn op -> handle_op(op) end)
          |> Comp.run!()

    No-op transactions (for tests):

        computation
        |> DB.Noop.with_handler()
        |> Comp.run!()

    ## Error Handling

    Operations that fail (e.g., invalid changeset) will throw via the
    Throw effect. Use `Throw.with_handler()` to catch errors:

        comp do
          user <- DB.insert(changeset)
          return(user)
        catch
          {:invalid_changeset, cs} -> return({:error, cs})
        end
        |> DB.Ecto.with_handler(Repo)
        |> Throw.with_handler()
        |> Comp.run!()

    ## Rollback on Throw

        comp do
          result <- DB.transact(comp do
            _ <- Throw.throw(:something_went_wrong)
            return(:never_reached)
          end)
          return(result)
        end
        |> DB.Ecto.with_handler(MyApp.Repo)
        |> Throw.with_handler()
        |> Comp.run!()
        # Transaction is rolled back, returns the throw error

    ## Nested Transactions

    Nested `transact` calls create savepoints (if supported by the database):

        comp do
          result <- DB.transact(comp do
            _ <- insert_parent()

            inner_result <- DB.transact(comp do
              _ <- insert_child()
              return(:inner_done)
            end)

            return({:outer_done, inner_result})
          end)
          return(result)
        end
        |> DB.Ecto.with_handler(MyApp.Repo)
        |> Comp.run!()

    ## Batched Reads

    For batched database reads using FiberPool, see `Skuld.Query.Contract`.
    """

    import Skuld.Comp.DefOp

    alias Skuld.Comp
    alias Skuld.Comp.Types
    alias Skuld.Effects.ChangeEvent

    @sig __MODULE__

    @doc false
    def sig, do: @sig

    #############################################################################
    ## Operation Structs — Writes
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
    ## Operation Structs — Transactions
    #############################################################################

    def_op(Transact, [:comp])
    def_op(Rollback, [:reason])

    #############################################################################
    ## Single Operations
    #############################################################################

    @doc """
    Insert a record from a changeset or ChangeEvent.

    Returns the inserted struct on success, throws on error.

    ## Example

        user <- DB.insert(User.changeset(attrs))
        user <- DB.insert(ChangeEvent.insert(changeset))
    """
    @spec insert(Ecto.Changeset.t() | ChangeEvent.t(), keyword()) :: Types.computation()
    def insert(input, opts \\ []) do
      Comp.effect(@sig, %Insert{input: input, opts: opts})
    end

    @doc """
    Update a record from a changeset or ChangeEvent.

    Returns the updated struct on success, throws on error.

    ## Example

        user <- DB.update(User.changeset(user, attrs))
    """
    @spec update(Ecto.Changeset.t() | ChangeEvent.t(), keyword()) :: Types.computation()
    def update(input, opts \\ []) do
      Comp.effect(@sig, %Update{input: input, opts: opts})
    end

    @doc """
    Insert or update a record (upsert) from a changeset or ChangeEvent.

    Returns the inserted/updated struct on success, throws on error.

    ## Example

        user <- DB.upsert(changeset, conflict_target: :email)
    """
    @spec upsert(Ecto.Changeset.t() | ChangeEvent.t(), keyword()) :: Types.computation()
    def upsert(input, opts \\ []) do
      Comp.effect(@sig, %Upsert{input: input, opts: opts})
    end

    @doc """
    Delete a record from a struct, changeset, or ChangeEvent.

    Returns `{:ok, struct}` on success, throws on error.

    ## Example

        {:ok, user} <- DB.delete(user)
        {:ok, user} <- DB.delete(ChangeEvent.delete(changeset))
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

        {count, users} <- DB.insert_all(User, changesets, returning: true)
        {count, nil} <- DB.insert_all(User, maps)
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
        {count, users} <- DB.update_all(User, changesets, returning: true)

        # Bulk update via query
        {count, nil} <- DB.update_all(User, [], query: query, set: [active: false])
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

        {count, users} <- DB.upsert_all(User, changesets,
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

        {count, nil} <- DB.delete_all(User, users)
    """
    @spec delete_all(module(), [struct() | Ecto.Changeset.t() | ChangeEvent.t()], keyword()) ::
            Types.computation()
    def delete_all(schema, entries, opts \\ []) do
      Comp.effect(@sig, %DeleteAll{schema: schema, entries: entries, opts: opts})
    end

    #############################################################################
    ## Transaction Operations
    #############################################################################

    @doc """
    Run a computation inside a database transaction.

    The inner computation will be executed within a transaction scope.
    On normal completion, the transaction commits. On throw, suspend,
    or explicit rollback, the transaction rolls back.

    ## Parameters

    - `inner_comp` - The computation to run inside the transaction

    ## Returns

    A computation that returns the result of the inner computation,
    or `{:rolled_back, reason}` if explicitly rolled back.

    ## Example

        comp do
          result <- DB.transact(comp do
            user <- DB.insert(changeset)
            order <- DB.insert(order_changeset)
            return({user, order})
          end)

          # result is {user, order} if successful
          return(result)
        end
        |> DB.Ecto.with_handler(MyApp.Repo)
        |> Comp.run!()
    """
    @spec transact(Types.computation()) :: Types.computation()
    def transact(inner_comp) do
      Comp.effect(@sig, %Transact{comp: inner_comp})
    end

    @doc """
    Explicitly roll back the current transaction.

    Must be called within a `transact` block. Returns `{:rolled_back, reason}`
    after the transaction is rolled back.

    ## Example

        comp do
          result <- DB.transact(comp do
            user <- DB.insert(changeset)

            if should_abort?(user) do
              _ <- DB.rollback({:aborted, user.id})
            end

            return(user)
          end)

          return(result)
        end
    """
    @spec rollback(term()) :: Types.computation()
    def rollback(reason) do
      Comp.effect(@sig, %Rollback{reason: reason})
    end
  end
end
