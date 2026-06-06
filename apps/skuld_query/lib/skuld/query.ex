defmodule Skuld.Query do
  @moduledoc """
  Syntax module providing the query do-notation macro.

  `use Skuld.Query` imports `query`, `defquery`, and `defqueryp` macros
  for writing batchable data-fetching computations.

  ## Usage

      use Skuld.Query

      query do
        user <- Users.get_user(id)
        orders <- Orders.get_by_user(user.id)
        {user, orders}
      end

      defquery user_with_orders(id) do
        user <- Users.get_user(id)
        orders <- Orders.get_by_user(user.id)
        {user, orders}
      end

  ## See Also

  - `Skuld.QueryContract` — define batchable fetch contracts with `deffetch`
  - `Skuld.Syntax` — computation block macros (`comp`, `defcomp`)
  """

  defmacro __using__(_opts) do
    quote do
      import Skuld.Query.QueryBlock
    end
  end
end
