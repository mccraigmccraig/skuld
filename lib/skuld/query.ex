defmodule Skuld.Query do
  @moduledoc """
  Public API for query wiring and batching.
  """

  alias Skuld.Comp

  @doc """
  Install an executor module for a single query contract.

  The executor module must implement the contract's `Executor` behaviour.

  ## Example

      comp
      |> Skuld.Query.with_executor(MyApp.Queries.Users, MyApp.Queries.Users.EctoExecutor)
      |> FiberPool.with_handler()
      |> Comp.run()
  """
  @spec with_executor(Comp.Types.computation(), module(), module()) ::
          Comp.Types.computation()
  def with_executor(comp, contract_module, executor_module) do
    Skuld.Query.Contract.with_executors(comp, [{contract_module, executor_module}])
  end
end
