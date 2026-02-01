defmodule Skuld.Fiber.FiberPool.BatchExecutor do
  @moduledoc """
  Batch executor registration and lookup.

  Executors are stored in env.state under a private key as a map of
  `{batch_key_pattern => executor}`. Uses `Comp.scoped` for proper
  scoping with automatic save/restore.

  Executors are functions that take a list of `{request_id, op}` tuples
  and return a computation yielding `%{request_id => result}`.

  ## Pattern Matching

  Batch keys support wildcard matching with `:_`:

      # Exact match
      comp
      |> BatchExecutor.with_executor({:db_fetch, User}, user_executor)

      # Wildcard match - handles any schema
      comp
      |> BatchExecutor.with_executor({:db_fetch, :_}, generic_db_executor)

  Exact matches take precedence over wildcard matches.

  ## Example

      # Production - real DB executor
      comp
      |> BatchExecutor.with_executor({:db_fetch, :_}, &DB.Executors.fetch_executor/1)
      |> FiberPool.run()

      # Test - mock executor
      comp
      |> BatchExecutor.with_executor({:db_fetch, User}, fn ops ->
        Comp.pure(Map.new(ops, fn {ref, _op} -> {ref, %User{id: 1}} end))
      end)
      |> FiberPool.run()
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env

  @state_key {__MODULE__, :executors}

  @type batch_key :: term()
  @type request_id :: reference()
  @type executor :: ([{request_id, term()}] -> Comp.Types.computation())
  @type registry :: %{batch_key => executor}

  @doc """
  Install a batch executor for a batch_key pattern in the current scope.

  The executor will be available for the duration of the computation and
  automatically removed when the scope exits.

  ## Parameters

  - `comp` - The computation to wrap
  - `batch_key` - The batch key pattern (supports `:_` wildcards)
  - `executor` - Function `([{request_id, op}] -> computation)` that executes the batch
  """
  @spec with_executor(Comp.Types.computation(), batch_key, executor) :: Comp.Types.computation()
  def with_executor(comp, batch_key, executor) do
    Comp.scoped(comp, fn env ->
      previous = Env.get_state(env, @state_key, %{})
      updated = Map.put(previous, batch_key, executor)

      {Env.put_state(env, @state_key, updated),
       fn value, e -> {value, Env.put_state(e, @state_key, previous)} end}
    end)
  end

  @doc """
  Install multiple batch executors at once.

  ## Example

      comp
      |> BatchExecutor.with_executors([
        {{:db_fetch, :_}, &DB.Executors.fetch_executor/1},
        {{:db_fetch_all, :_, :_}, &DB.Executors.fetch_all_executor/1}
      ])
  """
  @spec with_executors(Comp.Types.computation(), [{batch_key, executor}]) ::
          Comp.Types.computation()
  def with_executors(comp, executors) do
    Enum.reduce(executors, comp, fn {key, exec}, acc ->
      with_executor(acc, key, exec)
    end)
  end

  @doc """
  Look up executor for a batch_key.

  Tries exact match first, then falls back to wildcard pattern matching.
  Returns `nil` if no matching executor is found.
  """
  @spec get_executor(Comp.Types.env(), batch_key) :: executor | nil
  def get_executor(env, batch_key) do
    registry = Env.get_state(env, @state_key, %{})

    # Try exact match first
    case Map.get(registry, batch_key) do
      nil -> find_wildcard_match(registry, batch_key)
      executor -> executor
    end
  end

  @doc """
  Get the current executor registry from env.

  Useful for debugging or introspection.
  """
  @spec get_registry(Comp.Types.env()) :: registry
  def get_registry(env) do
    Env.get_state(env, @state_key, %{})
  end

  # Match batch_key against patterns with :_ wildcards
  # e.g., {:db_fetch, User} matches {:db_fetch, :_}
  defp find_wildcard_match(registry, batch_key) do
    Enum.find_value(registry, fn {pattern, executor} ->
      if pattern_matches?(pattern, batch_key), do: executor
    end)
  end

  defp pattern_matches?(pattern, key) when is_tuple(pattern) and is_tuple(key) do
    pattern_list = Tuple.to_list(pattern)
    key_list = Tuple.to_list(key)

    length(pattern_list) == length(key_list) and
      Enum.zip(pattern_list, key_list)
      |> Enum.all?(fn {p, k} -> p == :_ or p == k end)
  end

  defp pattern_matches?(pattern, key), do: pattern == key
end
