defmodule Skuld.Effects.DB do
  @moduledoc """
  Example database effect with automatic I/O batching.

  This module demonstrates how to implement a batchable effect using the
  FiberPool's batching infrastructure. Multiple concurrent `fetch` operations
  for the same schema are automatically batched into a single query.

  ## Usage

  To use DB effects with batching, you need to:
  1. Install batch executors using `DB.with_executors/1` or `BatchExecutor.with_executor/3`
  2. Run the computation in a FiberPool

  ## Example

      alias Skuld.Effects.{DB, FiberPool}
      alias Skuld.Syntax

      comp do
        # Submit multiple fibers that each fetch a user
        h1 <- FiberPool.submit(DB.fetch(User, 1))
        h2 <- FiberPool.submit(DB.fetch(User, 2))
        h3 <- FiberPool.submit(DB.fetch(User, 3))

        # Await all - the DB.fetch calls will be batched into one query
        FiberPool.await_all([h1, h2, h3])
      end
      |> DB.with_executors()
      |> Reader.with_value(:repo, MyApp.Repo)
      |> FiberPool.with_handler()
      |> FiberPool.run()

  ## How It Works

  1. Each `DB.fetch` call returns a `BatchSuspend` sentinel
  2. The FiberPool scheduler collects batch-suspended fibers
  3. When the run queue is empty, the scheduler groups suspensions by batch_key
  4. For each group, the registered executor runs a single batched query
  5. Results are distributed back to the waiting fibers
  """

  alias Skuld.Comp
  alias Skuld.Fiber.FiberPool.{BatchSuspend, BatchExecutor}

  #############################################################################
  ## Operation Structs
  #############################################################################

  defmodule Fetch do
    @moduledoc """
    Operation for fetching a single record by ID.

    Batch key: `{:db_fetch, schema}`
    """
    defstruct [:schema, :id]

    @type t :: %__MODULE__{
            schema: module(),
            id: term()
          }
  end

  defmodule FetchAll do
    @moduledoc """
    Operation for fetching all records matching a filter.

    Batch key: `{:db_fetch_all, schema, filter_key}`
    """
    defstruct [:schema, :filter_key, :filter_value]

    @type t :: %__MODULE__{
            schema: module(),
            filter_key: atom(),
            filter_value: term()
          }
  end

  #############################################################################
  ## IBatchable Implementations
  #############################################################################

  defimpl Skuld.Fiber.FiberPool.IBatchable, for: Skuld.Effects.DB.Fetch do
    def batch_key(%{schema: schema}), do: {:db_fetch, schema}
  end

  defimpl Skuld.Fiber.FiberPool.IBatchable, for: Skuld.Effects.DB.FetchAll do
    def batch_key(%{schema: schema, filter_key: key}), do: {:db_fetch_all, schema, key}
  end

  #############################################################################
  ## Public API
  #############################################################################

  @doc """
  Fetch a single record by ID.

  The fetch operation suspends the current fiber and waits for batch execution.
  Multiple fetch operations for the same schema are automatically batched.

  Returns `nil` if the record is not found.
  """
  @spec fetch(module(), term()) :: Comp.Types.computation()
  def fetch(schema, id) do
    fn env, k ->
      op = %Fetch{schema: schema, id: id}

      suspend = BatchSuspend.new(
        op,
        fn result -> k.(result, env) end
      )

      {suspend, env}
    end
  end

  @doc """
  Fetch all records matching a filter.

  Multiple fetch_all operations with the same schema and filter_key are
  automatically batched.

  Returns a list of matching records.
  """
  @spec fetch_all(module(), atom(), term()) :: Comp.Types.computation()
  def fetch_all(schema, filter_key, filter_value) do
    fn env, k ->
      op = %FetchAll{schema: schema, filter_key: filter_key, filter_value: filter_value}

      suspend = BatchSuspend.new(
        op,
        fn result -> k.(result, env) end
      )

      {suspend, env}
    end
  end

  #############################################################################
  ## Batch Executors
  #############################################################################

  @doc """
  Install standard DB batch executors for a computation.

  This installs executors for:
  - `{:db_fetch, :_}` - Batched single-record fetches
  - `{:db_fetch_all, :_, :_}` - Batched multi-record fetches

  The executors use `:repo` from Reader to perform queries.

  ## Example

      comp do
        # ... DB operations ...
      end
      |> DB.with_executors()
      |> Reader.with_value(:repo, MyApp.Repo)
      |> FiberPool.run()
  """
  @spec with_executors(Comp.Types.computation()) :: Comp.Types.computation()
  def with_executors(comp) do
    comp
    |> BatchExecutor.with_executors([
      {{:db_fetch, :_}, &__MODULE__.Executors.fetch_executor/1},
      {{:db_fetch_all, :_, :_}, &__MODULE__.Executors.fetch_all_executor/1}
    ])
  end

  @doc """
  Install a custom fetch executor.

  Useful for testing with mock data.
  """
  @spec with_fetch_executor(Comp.Types.computation(), module(), BatchExecutor.executor()) ::
          Comp.Types.computation()
  def with_fetch_executor(comp, schema, executor) do
    BatchExecutor.with_executor(comp, {:db_fetch, schema}, executor)
  end

  @doc """
  Install a custom fetch_all executor.
  """
  @spec with_fetch_all_executor(
          Comp.Types.computation(),
          module(),
          atom(),
          BatchExecutor.executor()
        ) :: Comp.Types.computation()
  def with_fetch_all_executor(comp, schema, filter_key, executor) do
    BatchExecutor.with_executor(comp, {:db_fetch_all, schema, filter_key}, executor)
  end
end

defmodule Skuld.Effects.DB.Executors do
  @moduledoc """
  Default batch executors for DB operations.

  These executors use Ecto to perform batched queries. They expect
  `:repo` to be available via the Reader effect.
  """

  alias Skuld.Comp
  alias Skuld.Effects.Reader

  @doc """
  Executor for `DB.Fetch` operations.

  Batches multiple single-record fetches into a single `WHERE id IN (...)` query.
  """
  def fetch_executor(ops) do
    # All ops have the same schema (grouped by batch_key)
    {_first_ref, first_op} = hd(ops)
    schema = first_op.schema

    # Collect unique IDs
    ids = ops |> Enum.map(fn {_ref, %{id: id}} -> id end) |> Enum.uniq()

    Comp.bind(Reader.ask(:repo), fn repo ->
      # Perform batched query
      results = repo.all(schema, ids)
      results_by_id = Map.new(results, &{&1.id, &1})

      # Map results back to request_ids
      result_map =
        Map.new(ops, fn {ref, %{id: id}} ->
          {ref, Map.get(results_by_id, id)}
        end)

      Comp.pure(result_map)
    end)
  end

  @doc """
  Executor for `DB.FetchAll` operations.

  Batches multiple fetch_all operations into a single query with all filter values.
  """
  def fetch_all_executor(ops) do
    # All ops have same schema and filter_key (grouped by batch_key)
    {_first_ref, first_op} = hd(ops)
    schema = first_op.schema
    filter_key = first_op.filter_key

    # Collect unique filter values
    values = ops |> Enum.map(fn {_ref, %{filter_value: v}} -> v end) |> Enum.uniq()

    Comp.bind(Reader.ask(:repo), fn repo ->
      # Perform batched query
      results = repo.all_by(schema, filter_key, values)
      grouped = Enum.group_by(results, &Map.get(&1, filter_key))

      # Map results back to request_ids
      result_map =
        Map.new(ops, fn {ref, %{filter_value: v}} ->
          {ref, Map.get(grouped, v, [])}
        end)

      Comp.pure(result_map)
    end)
  end
end
