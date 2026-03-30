# Stateless test handler for Port.Repo.
#
# Provides a function handler via new/1. Write operations apply changeset
# changes and return {:ok, struct}. Read operations go through a
# user-supplied fallback function, or raise.
#
# ## Usage
#
#     comp
#     |> Port.with_handler(%{Port.Repo => Port.Repo.Test.new()})
#     |> Throw.with_handler()
#     |> Comp.run!()
#
#     # With fallback for reads:
#     comp
#     |> Port.with_handler(%{
#       Port.Repo => Port.Repo.Test.new(
#         fallback_fn: fn
#           :all, [User] -> [%User{id: 1, name: "Alice"}]
#           :get, [User, 1] -> %User{id: 1, name: "Alice"}
#         end
#       )
#     })
#     |> Throw.with_handler()
#     |> Comp.run!()
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.Test do
    @moduledoc """
    Stateless test handler for `Port.Repo`.

    Provides a function handler via `new/1` for use in a `Port.with_handler/3`
    registry. Write operations (`insert`, `update`, `delete`) apply changeset
    changes and return `{:ok, struct}`. All read operations go through an
    optional fallback function, or raise a clear error.

    This applies the "fail when consistency cannot be proven" approach —
    reads never silently return `nil` or `[]` because the adapter has no
    basis for claiming a record does or doesn't exist.

    ## Usage

        alias Skuld.Effects.Port
        alias Skuld.Effects.Port.Repo

        # Writes only — reads will raise:
        comp
        |> Port.with_handler(%{Repo => Repo.Test.new()})
        |> Throw.with_handler()
        |> Comp.run!()

        # With fallback for reads:
        comp
        |> Port.with_handler(%{
          Repo => Repo.Test.new(
            fallback_fn: fn
              :get, [User, 1] -> %User{id: 1, name: "Alice"}
              :all, [User] -> [%User{id: 1, name: "Alice"}]
            end
          )
        })
        |> Throw.with_handler()
        |> Comp.run!()

    ## Differences from Repo.InMemory

    `Repo.Test` is stateless — writes apply changesets and return `{:ok, struct}`
    but nothing is stored. There is no read-after-write consistency.

    `Repo.InMemory` is stateful — writes store records and PK-based reads can
    find them. Use `Repo.InMemory` when your test needs read-after-write
    consistency. Use `Repo.Test` when you only need fire-and-forget writes.
    """

    @doc """
    Create a new Test handler function.

    Returns a 3-arity function `(mod, operation, args) -> result` suitable
    for use as a resolver in `Port.with_handler/3`.

    ## Options

      * `:fallback_fn` - a 2-arity function `(operation, args) -> result` that
        handles read operations. If the function raises `FunctionClauseError`
        (no matching clause), dispatch falls through to an error. If omitted,
        all reads raise immediately.

    ## Examples

        # Writes only
        Repo.Test.new()

        # With fallback for specific reads
        Repo.Test.new(
          fallback_fn: fn
            :get, [User, 1] -> %User{id: 1, name: "Alice"}
            :all, [User] -> [%User{id: 1, name: "Alice"}]
            :exists?, [User] -> true
          end
        )
    """
    @spec new(keyword()) :: (module(), atom(), [term()] -> term())
    def new(opts \\ []) do
      fallback_fn = Keyword.get(opts, :fallback_fn, nil)

      fn _mod, operation, args ->
        dispatch(operation, args, fallback_fn)
      end
    end

    # -----------------------------------------------------------------
    # Write Operations — always authoritative
    # -----------------------------------------------------------------

    defp dispatch(:insert, [changeset], _fallback_fn) do
      {:ok, safe_apply_changes(changeset)}
    end

    defp dispatch(:update, [changeset], _fallback_fn) do
      {:ok, safe_apply_changes(changeset)}
    end

    defp dispatch(:delete, [record], _fallback_fn) do
      {:ok, record}
    end

    # -----------------------------------------------------------------
    # Read and bulk operations — fallback or error
    # -----------------------------------------------------------------

    defp dispatch(operation, args, fallback_fn)
         when operation in [
                :get,
                :get!,
                :get_by,
                :get_by!,
                :one,
                :one!,
                :all,
                :exists?,
                :aggregate,
                :update_all,
                :delete_all
              ] do
      try_fallback(fallback_fn, operation, args)
    end

    # -----------------------------------------------------------------
    # Fallback dispatch
    # -----------------------------------------------------------------

    defp try_fallback(nil, operation, args) do
      raise_no_fallback(operation, args)
    end

    defp try_fallback(fallback_fn, operation, args) when is_function(fallback_fn, 2) do
      fallback_fn.(operation, args)
    rescue
      FunctionClauseError -> raise_no_fallback(operation, args)
    end

    defp raise_no_fallback(operation, args) do
      raise ArgumentError, """
      Skuld.Effects.Port.Repo.Test cannot service :#{operation} with args #{inspect(args)}.

      The Test adapter can only answer authoritatively for:
        - Write operations (insert, update, delete)

      For all other operations, register a fallback function:

          Repo.Test.new(
            fallback_fn: fn
              :#{operation}, #{inspect(args)} -> # your result here
            end
          )
      """
    end

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------

    defp safe_apply_changes(%Ecto.Changeset{} = changeset) do
      Ecto.Changeset.apply_changes(changeset)
    end
  end
end
