defmodule Skuld.Query.Cache do
  @moduledoc """
  Composable caching layer for `Query.Contract` queries.

  Provides:
  - **Cross-batch result caching** — identical queries across batch rounds
    return cached results without re-executing
  - **Within-batch request deduplication** — identical queries in the same
    batch round are sent to the executor only once, with the result fanned
    out to all requesting fibers

  ## Usage

      comp
      |> QueryCache.with_executor(Users, Users.EctoExecutor)
      |> FiberPool.with_handler()
      |> Comp.run()

      # Multiple contracts (shared cache scope):
      comp
      |> QueryCache.with_executors([
        {Users, Users.EctoExecutor},
        {Orders, Orders.EctoExecutor}
      ])
      |> FiberPool.with_handler()
      |> Comp.run()

  ## Cache Scope

  The cache is scoped per computation run. It's initialised as an empty map
  by `Comp.scoped` and cleaned up on scope exit. No TTL, no eviction.

  Multiple `with_executors`/`with_executor` calls share a single cache scope.
  The first call creates the cache; subsequent calls reuse the existing cache
  and register their executors against it. Only the outermost scope performs
  cleanup.

  ## Cache Key

  `{batch_key, op_struct}` where:
  - `batch_key` is `{ContractModule, :query_name}`
  - `op_struct` is the operation struct (e.g. `%Users.GetUser{id: "123"}`)

  Structural equality on Elixir structs provides correct comparison.

  ## Per-Query Opt-Out

  Queries declared with `cache: false` bypass caching entirely:

      deffetch get_random_user() :: User.t(), cache: false

  ## Error Handling

  Executor failures are not cached. When an executor produces a Throw, the error
  propagates normally and the cache is not polluted — subsequent requests for the
  same query go to the executor again.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Fiber.FiberPool.BatchExecutor

  @cache_key {__MODULE__, :cache}

  @doc """
  Install caching-wrapped executors for multiple contracts.

  Initialises a scoped cache and registers caching-wrapped executors for
  all query operations in each contract. Queries with `cacheable: false`
  (from `deffetch ..., cache: false`) are registered with raw dispatch
  that bypasses the cache entirely.

  ## Example

      comp
      |> QueryCache.with_executors([
        {Users, Users.EctoExecutor},
        {Orders, Orders.EctoExecutor}
      ])
      |> FiberPool.with_handler()
      |> Comp.run()
  """
  @spec with_executors(Comp.Types.computation(), [{module(), module()}]) ::
          Comp.Types.computation()
  def with_executors(comp, contract_executor_pairs) do
    # Build the list of {batch_key, caching_wrapper} tuples for all operations
    executor_entries =
      Enum.flat_map(contract_executor_pairs, fn {contract_module, executor_module} ->
        contract_module.__query_operations__()
        |> Enum.map(fn op ->
          batch_key = {contract_module, op.name}

          executor_fn =
            if op.cacheable do
              make_caching_wrapper(contract_module, executor_module, op.name, batch_key)
            else
              # Non-cacheable: raw dispatch, bypasses cache entirely
              fn ops -> contract_module.__dispatch__(executor_module, op.name, ops) end
            end

          {batch_key, executor_fn}
        end)
      end)

    # Install the cache scope and all wrapped executors
    comp
    |> init_cache_scope()
    |> BatchExecutor.with_executors(executor_entries)
  end

  @doc """
  Install a caching-wrapped executor for a single contract.

  Shorthand for `with_executors(comp, [{contract_module, executor_module}])`.
  """
  @spec with_executor(Comp.Types.computation(), module(), module()) ::
          Comp.Types.computation()
  def with_executor(comp, contract_module, executor_module) do
    with_executors(comp, [{contract_module, executor_module}])
  end

  # -------------------------------------------------------------------
  # Cache Scope
  # -------------------------------------------------------------------

  defp init_cache_scope(comp) do
    Comp.scoped(comp, fn env ->
      case Env.get_state(env, @cache_key, nil) do
        nil ->
          # No cache exists — create a new scope
          env_with_cache = Env.put_state(env, @cache_key, %{})

          cleanup = fn value, cleanup_env ->
            restored_env = %{cleanup_env | state: Map.delete(cleanup_env.state, @cache_key)}
            {value, restored_env}
          end

          {env_with_cache, cleanup}

        _existing_cache ->
          # Cache already established by an outer with_executors — reuse it
          cleanup = fn value, cleanup_env -> {value, cleanup_env} end
          {env, cleanup}
      end
    end)
  end

  # -------------------------------------------------------------------
  # Caching Wrapper
  # -------------------------------------------------------------------

  defp make_caching_wrapper(contract_module, executor_module, query_name, batch_key) do
    fn ops ->
      # The wrapper is a computation — it needs access to env to read/write cache
      fn env, k ->
        cache = Env.get_state(env, @cache_key, %{})

        # Partition ops into cache hits and misses
        {hit_results, miss_ops} = partition_cached(ops, cache, batch_key)

        if miss_ops == [] do
          # All cache hits — return immediately
          k.(hit_results, env)
        else
          # Within-batch dedup: group identical ops, send only unique ops to executor
          {unique_ops, dedup_groups} = dedup_ops(miss_ops)

          # Call real executor for unique misses only
          executor_comp =
            contract_module.__dispatch__(executor_module, query_name, unique_ops)

          Comp.call(
            Comp.bind(executor_comp, fn unique_results ->
              # Fan out results to all refs that requested each unique op,
              # and build cache entries
              {fanned_results, new_cache_entries} =
                fan_out_results(unique_results, unique_ops, dedup_groups, batch_key)

              # Return a computation that updates env.state and returns merged results
              fn inner_env, inner_k ->
                updated_cache =
                  Map.merge(Env.get_state(inner_env, @cache_key, %{}), new_cache_entries)

                updated_env = Env.put_state(inner_env, @cache_key, updated_cache)

                merged_results = Map.merge(hit_results, fanned_results)
                inner_k.(merged_results, updated_env)
              end
            end),
            env,
            k
          )
        end
      end
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  # Group miss_ops by op value for within-batch deduplication.
  #
  # Returns {unique_ops, dedup_groups} where:
  # - unique_ops: [{ref, op}] with one representative ref per unique op
  # - dedup_groups: %{op => [ref1, ref2, ...]} mapping each unique op to ALL refs
  defp dedup_ops(miss_ops) do
    # Build groups: %{op => [ref, ...]} (refs in original order)
    groups =
      Enum.reduce(miss_ops, %{}, fn {ref, op}, acc ->
        Map.update(acc, op, [ref], fn refs -> refs ++ [ref] end)
      end)

    # Build unique_ops using first ref for each unique op
    unique_ops =
      Enum.reduce(miss_ops, {MapSet.new(), []}, fn {ref, op}, {seen, acc} ->
        if MapSet.member?(seen, op) do
          {seen, acc}
        else
          {MapSet.put(seen, op), [{ref, op} | acc]}
        end
      end)
      |> elem(1)
      |> Enum.reverse()

    {unique_ops, groups}
  end

  # Expand executor results from unique refs to all requesting refs,
  # and build cache entries for the new results.
  defp fan_out_results(unique_results, unique_ops, dedup_groups, batch_key) do
    Enum.reduce(unique_ops, {%{}, %{}}, fn {ref, op}, {results_acc, cache_acc} ->
      result = Map.fetch!(unique_results, ref)
      all_refs = Map.fetch!(dedup_groups, op)

      # Fan out result to all refs for this op
      expanded =
        Enum.reduce(all_refs, results_acc, fn r, acc ->
          Map.put(acc, r, result)
        end)

      # Add cache entry
      {expanded, Map.put(cache_acc, {batch_key, op}, result)}
    end)
  end

  defp partition_cached(ops, cache, batch_key) do
    Enum.reduce(ops, {%{}, []}, fn {ref, op}, {hits, misses} ->
      cache_key = {batch_key, op}

      case Map.fetch(cache, cache_key) do
        {:ok, cached_result} ->
          {Map.put(hits, ref, cached_result), misses}

        :error ->
          {hits, [{ref, op} | misses]}
      end
    end)
    |> then(fn {hits, misses} -> {hits, Enum.reverse(misses)} end)
  end
end
