defmodule Skuld.Effects.Random do
  @moduledoc """
  Random effect - generate random values.

  Provides three handler modes:

  - **Production** (`with_handler/1`): Uses Erlang's `:rand` module for
    cryptographically suitable random values.

  - **Seeded** (`with_seed_handler/2`): Uses a deterministic seed for
    reproducible random sequences - ideal for testing.

  - **Fixed** (`with_fixed_handler/2`): Returns values from a fixed sequence,
    cycling when exhausted - useful for specific test scenarios.

  ## Production Usage

      use Skuld.Syntax
      alias Skuld.Comp
      alias Skuld.Effects.Random

      comp do
        f <- Random.random()
        i <- Random.random_int(1, 100)
        elem <- Random.random_element([:a, :b, :c])
        {f, i, elem}
      end
      |> Random.with_handler()
      |> Comp.run!()
      #=> {0.7234..., 42, :b}

  ## Seeded Usage (Deterministic)

      # Same seed produces same sequence - reproducible tests
      comp do
        a <- Random.random()
        b <- Random.random()
        {a, b}
      end
      |> Random.with_seed_handler(seed: {1, 2, 3})
      |> Comp.run!()
      #=> {0.123..., 0.456...}  # always the same

  ## Fixed Usage (Test Scenarios)

      # Return specific values for testing edge cases
      comp do
        a <- Random.random()
        b <- Random.random()
        c <- Random.random()
        {a, b, c}
      end
      |> Random.with_fixed_handler(values: [0.0, 0.5, 1.0])
      |> Comp.run!()
      #=> {0.0, 0.5, 1.0}
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## State Structures
  #############################################################################

  defmodule SeededState do
    @moduledoc false
    defstruct [:rand_state]
  end

  defmodule FixedState do
    @moduledoc false
    defstruct values: [], original: []
  end

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(RandomFloat)
  def_op(RandomInt, [:min, :max])
  def_op(RandomElement, [:list])
  def_op(Shuffle, [:list])

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Generate a random float between 0.0 (inclusive) and 1.0 (exclusive).

  ## Example

      comp do
        f <- Random.random()
        f
      end
      |> Random.with_handler()
      |> Comp.run!()
      #=> 0.7234...
  """
  @spec random() :: Types.computation()
  def random do
    Comp.effect(@sig, %RandomFloat{})
  end

  @doc """
  Generate a random integer in the range `min..max` (inclusive).

  ## Example

      comp do
        i <- Random.random_int(1, 6)
        i
      end
      |> Random.with_handler()
      |> Comp.run!()
      #=> 4
  """
  @spec random_int(integer(), integer()) :: Types.computation()
  def random_int(min, max) when is_integer(min) and is_integer(max) and min <= max do
    Comp.effect(@sig, %RandomInt{min: min, max: max})
  end

  @doc """
  Pick a random element from a non-empty list.

  ## Example

      comp do
        elem <- Random.random_element([:rock, :paper, :scissors])
        elem
      end
      |> Random.with_handler()
      |> Comp.run!()
      #=> :scissors
  """
  @spec random_element(nonempty_list(a)) :: Types.computation() when a: term()
  def random_element([_ | _] = list) do
    Comp.effect(@sig, %RandomElement{list: list})
  end

  @doc """
  Shuffle a list randomly.

  ## Example

      comp do
        shuffled <- Random.shuffle([1, 2, 3, 4, 5])
        shuffled
      end
      |> Random.with_handler()
      |> Comp.run!()
      #=> [3, 1, 5, 2, 4]
  """
  @spec shuffle(list(a)) :: Types.computation() when a: term()
  def shuffle(list) when is_list(list) do
    Comp.effect(@sig, %Shuffle{list: list})
  end

  #############################################################################
  ## Production Handler (uses :rand)
  #############################################################################

  @doc """
  Install a random handler using Erlang's `:rand` module.

  Uses the default random algorithm seeded from system entropy.
  Not deterministic across runs.

  ## Example

      comp do
        f <- Random.random()
        f
      end
      |> Random.with_handler()
      |> Comp.run!()
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, @sig, &handle_rand/3)
  end

  defp handle_rand(%RandomFloat{}, env, k) do
    k.(:rand.uniform(), env)
  end

  defp handle_rand(%RandomInt{min: min, max: max}, env, k) do
    # :rand.uniform(n) returns 1..n, so adjust for min..max range
    value = min + :rand.uniform(max - min + 1) - 1
    k.(value, env)
  end

  defp handle_rand(%RandomElement{list: list}, env, k) do
    index = :rand.uniform(length(list)) - 1
    k.(Enum.at(list, index), env)
  end

  defp handle_rand(%Shuffle{list: list}, env, k) do
    k.(Enum.shuffle(list), env)
  end

  #############################################################################
  ## Seeded Handler (Deterministic)
  #############################################################################

  @doc """
  Install a deterministic random handler with a fixed seed.

  Uses Erlang's `:rand` module with explicit state management, ensuring
  the same seed always produces the same sequence. Ideal for testing.

  ## Options

  - `:seed` - A seed tuple `{s1, s2, s3}` for the random generator.
    Default: `{1, 2, 3}`.
  - `:algorithm` - The random algorithm to use. Default: `:exsss`.

  ## Example

      # Same seed = same results
      comp do
        a <- Random.random()
        b <- Random.random_int(1, 10)
        {a, b}
      end
      |> Random.with_seed_handler(seed: {42, 42, 42})
      |> Comp.run!()
      #=> {0.123..., 7}  # always the same with this seed
  """
  @spec with_seed_handler(Types.computation(), keyword()) :: Types.computation()
  def with_seed_handler(comp, opts \\ []) do
    seed = Keyword.get(opts, :seed, {1, 2, 3})
    algorithm = Keyword.get(opts, :algorithm, :exsss)

    initial_rand_state = :rand.seed_s(algorithm, seed)
    initial_state = %SeededState{rand_state: initial_rand_state}

    comp
    |> Comp.scoped(fn env ->
      previous = Env.get_state(env, @sig)
      modified = Env.put_state(env, @sig, initial_state)

      finally_k = fn value, e ->
        restored_env =
          case previous do
            nil -> %{e | state: Map.delete(e.state, @sig)}
            val -> Env.put_state(e, @sig, val)
          end

        {value, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &handle_seeded/3)
  end

  defp handle_seeded(%RandomFloat{}, env, k) do
    %SeededState{rand_state: rand_state} = Env.get_state(env, @sig)
    {value, new_rand_state} = :rand.uniform_s(rand_state)
    new_env = Env.put_state(env, @sig, %SeededState{rand_state: new_rand_state})
    k.(value, new_env)
  end

  defp handle_seeded(%RandomInt{min: min, max: max}, env, k) do
    %SeededState{rand_state: rand_state} = Env.get_state(env, @sig)
    {raw, new_rand_state} = :rand.uniform_s(max - min + 1, rand_state)
    value = min + raw - 1
    new_env = Env.put_state(env, @sig, %SeededState{rand_state: new_rand_state})
    k.(value, new_env)
  end

  defp handle_seeded(%RandomElement{list: list}, env, k) do
    %SeededState{rand_state: rand_state} = Env.get_state(env, @sig)
    {raw, new_rand_state} = :rand.uniform_s(length(list), rand_state)
    index = raw - 1
    new_env = Env.put_state(env, @sig, %SeededState{rand_state: new_rand_state})
    k.(Enum.at(list, index), new_env)
  end

  defp handle_seeded(%Shuffle{list: list}, env, k) do
    # Fisher-Yates shuffle with explicit state threading
    %SeededState{rand_state: rand_state} = Env.get_state(env, @sig)
    {shuffled, new_rand_state} = shuffle_with_state(list, rand_state)
    new_env = Env.put_state(env, @sig, %SeededState{rand_state: new_rand_state})
    k.(shuffled, new_env)
  end

  # Fisher-Yates shuffle with explicit random state using tuple for O(1) access
  defp shuffle_with_state([], rand_state), do: {[], rand_state}
  defp shuffle_with_state([single], rand_state), do: {[single], rand_state}

  defp shuffle_with_state(list, rand_state) do
    tuple = List.to_tuple(list)
    n = tuple_size(tuple)

    {final_tuple, final_state} =
      Enum.reduce((n - 1)..1//-1, {tuple, rand_state}, fn i, {acc_tuple, acc_state} ->
        # :rand.uniform_s(n) returns 1..n, we need 0..i
        {raw_j, new_state} = :rand.uniform_s(i + 1, acc_state)
        j = raw_j - 1

        val_i = elem(acc_tuple, i)
        val_j = elem(acc_tuple, j)

        swapped =
          acc_tuple
          |> put_elem(i, val_j)
          |> put_elem(j, val_i)

        {swapped, new_state}
      end)

    {Tuple.to_list(final_tuple), final_state}
  end

  #############################################################################
  ## Fixed Handler (Test Scenarios)
  #############################################################################

  @doc """
  Install a handler that returns values from a fixed sequence.

  Useful for testing specific scenarios where you need exact control
  over random values. When the sequence is exhausted, it cycles back
  to the beginning.

  ## Options

  - `:values` - A list of values to return. For `random()` these should
    be floats 0.0-1.0. For `random_int/2` and `random_element/1`, the
    handler uses these as indices (mod list length).

  ## Example

      comp do
        a <- Random.random()
        b <- Random.random()
        c <- Random.random()
        {a, b, c}
      end
      |> Random.with_fixed_handler(values: [0.1, 0.5, 0.9])
      |> Comp.run!()
      #=> {0.1, 0.5, 0.9}

      # Cycles when exhausted
      comp do
        a <- Random.random()
        b <- Random.random()
        c <- Random.random()
        d <- Random.random()
        {a, b, c, d}
      end
      |> Random.with_fixed_handler(values: [0.0, 1.0])
      |> Comp.run!()
      #=> {0.0, 1.0, 0.0, 1.0}
  """
  @spec with_fixed_handler(Types.computation(), keyword()) :: Types.computation()
  def with_fixed_handler(comp, opts \\ []) do
    values = Keyword.get(opts, :values, [0.5])

    initial_state = %FixedState{values: values, original: values}

    comp
    |> Comp.scoped(fn env ->
      previous = Env.get_state(env, @sig)
      modified = Env.put_state(env, @sig, initial_state)

      finally_k = fn value, e ->
        restored_env =
          case previous do
            nil -> %{e | state: Map.delete(e.state, @sig)}
            val -> Env.put_state(e, @sig, val)
          end

        {value, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &handle_fixed/3)
  end

  defp handle_fixed(%RandomFloat{}, env, k) do
    {value, new_env} = next_fixed_value(env)
    k.(value, new_env)
  end

  defp handle_fixed(%RandomInt{min: min, max: max}, env, k) do
    {raw, new_env} = next_fixed_value(env)
    # Interpret raw as a position in the range
    range_size = max - min + 1
    value = (min + trunc(raw * range_size)) |> min(max)
    k.(value, new_env)
  end

  defp handle_fixed(%RandomElement{list: list}, env, k) do
    {raw, new_env} = next_fixed_value(env)
    index = trunc(raw * length(list)) |> min(length(list) - 1)
    k.(Enum.at(list, index), new_env)
  end

  defp handle_fixed(%Shuffle{list: list}, env, k) do
    # For fixed handler, just reverse the list as a deterministic "shuffle"
    # (Real shuffle would need multiple values)
    k.(Enum.reverse(list), env)
  end

  defp next_fixed_value(env) do
    state = Env.get_state(env, @sig)

    {value, remaining} =
      case state.values do
        [v | rest] ->
          {v, rest}

        [] ->
          [v | rest] = state.original
          {v, rest}
      end

    new_env = Env.put_state(env, @sig, %{state | values: remaining})
    {value, new_env}
  end

  #############################################################################
  ## IHandler Implementation (not used directly)
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(_op, _env, _k) do
    raise "Random.handle/3 should not be called directly - use with_handler/1, with_seed_handler/2, or with_fixed_handler/2"
  end
end
