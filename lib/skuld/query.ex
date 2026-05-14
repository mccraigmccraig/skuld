defmodule Skuld.Query do
  @moduledoc """
  Primary API for query contracts, wiring, and caching.

  ## Defining a query contract

      defmodule MyApp.Queries do
        use Skuld.Query

        deffetch get_user(id :: String.t()) :: User.t() | nil
        deffetch get_orders(user_id :: String.t()) :: [Order.t()]
      end

  ## Wiring executors

      comp
      |> Skuld.Query.with_executor(MyApp.Queries, MyApp.Queries.EctoExecutor)
      |> FiberPool.with_handler()
      |> Comp.run()

  ## With caching

      comp
      |> Skuld.Query.with_cached_executor(MyApp.Queries, MyApp.Queries.EctoExecutor)
      |> FiberPool.with_handler()
      |> Comp.run()
  """

  alias Skuld.Comp

  @doc false
  defmacro __using__(opts) do
    quote do
      use Skuld.Query.Contract, unquote(opts)
    end
  end

  @doc """
  Install an executor module for a single query contract.

  The executor module must implement the contract's callbacks.
  """
  @spec with_executor(Comp.Types.computation(), module(), module()) ::
          Comp.Types.computation()
  def with_executor(comp, contract_module, executor_module) do
    Skuld.Query.Contract.with_executors(comp, [{contract_module, executor_module}])
  end

  @doc """
  Install executor modules for multiple query contracts.
  Accepts either a list of `{contract_module, executor_module}` tuples or a map.
  """
  defdelegate with_executors(comp, pairs), to: Skuld.Query.Contract

  @doc """
  Install a caching-wrapped executor for a single contract.
  Shorthand for `with_cached_executors/2`.
  """
  defdelegate with_cached_executor(comp, contract_module, executor_module), to: Skuld.Query.Cache

  @doc """
  Install caching-wrapped executors for multiple contracts.
  Initialises a scoped cache and wraps executors so identical queries
  return cached results without re-executing.
  """
  defdelegate with_cached_executors(comp, pairs), to: Skuld.Query.Cache
end
