# Stateless stub Repo handler for tests.
#
# Thin wrapper around DoubleDown.Repo.Stub providing skuld's
# effect-based handler API.
#
defmodule Skuld.Repo.Stub do
  @moduledoc """
  Stateless stub Repo handler for tests.

  Thin wrapper around `DoubleDown.Repo.Stub` that provides skuld's
  handler API. Write operations (`insert`, `update`, `delete`) apply
  changeset changes and return `{:ok, struct}` but store nothing.
  Read operations go through an optional fallback function, or raise.

  ## Usage

      alias Skuld.Effects.Port
      alias Skuld.Repo

      # Writes only — reads will raise:
      comp
      |> Port.with_fn_handler(Repo.Stub.new())
      |> Comp.run!()

      # With fallback for reads:
      comp
      |> Port.with_fn_handler(Repo.Stub.new(
        fallback_fn: fn
          :get, [User, 1] -> %User{id: 1, name: "Alice"}
          :all, [User] -> [%User{id: 1, name: "Alice"}]
        end
      ))
      |> Comp.run!()

  ## Differences from Repo.InMemory / Repo.OpenInMemory

  `Repo.Stub` is stateless — writes apply changesets and return
  `{:ok, struct}` but nothing is stored. There is no read-after-write
  consistency. Use `Repo.Stub` when you only need fire-and-forget writes.

  ## Fallback function

  The fallback function receives `(operation, args)` — the skuld-idiomatic
  2-arity convention. The wrapper adapts it to DD's 3-arity
  `(contract, operation, args)` convention internally.
  """

  alias DoubleDown.Repo.Stub, as: DDStub

  @doc """
  Create a new Stub handler function.

  Returns a 3-arity function `(contract, operation, args) -> result` suitable
  for use with `Port.with_fn_handler/2`.

  ## Options

    * `:fallback_fn` - a 2-arity function `(operation, args) -> result` that
      handles read operations.

  ## Examples

      Repo.Stub.new()
      Repo.Stub.new(
        fallback_fn: fn
          :get, [User, 1] -> %User{id: 1, name: "Alice"}
          :all, [User] -> [%User{id: 1, name: "Alice"}]
        end
      )
  """
  @spec new(keyword()) :: (module(), atom(), [term()] -> term())
  def new(opts \\ []) do
    skuld_fallback = Keyword.get(opts, :fallback_fn, nil)

    dd_fallback =
      if skuld_fallback do
        fn _contract, op, args -> skuld_fallback.(op, args) end
      else
        nil
      end

    DDStub.new(dd_fallback)
  end
end
