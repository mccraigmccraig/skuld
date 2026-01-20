defmodule Skuld.Effects.Random.Seed do
  @moduledoc """
  Deterministic seeded random handler for Random effect.

  Uses Erlang's `:rand` module with explicit state management, ensuring
  the same seed always produces the same sequence. Ideal for testing.

  ## Example

      # Same seed = same results
      comp do
        a <- Random.random()
        b <- Random.random_int(1, 10)
        {a, b}
      end
      |> Random.Seed.with_handler(seed: {42, 42, 42})
      |> Comp.run!()
      #=> {0.123..., 7}  # always the same with this seed
  """

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Effects.Random.{RandomFloat, RandomInt, RandomElement, Shuffle}

  @sig Skuld.Effects.Random

  defmodule State do
    @moduledoc false
    defstruct [:rand_state]
  end

  @doc """
  Install a deterministic random handler with a fixed seed.

  ## Options

  - `:seed` - A seed tuple `{s1, s2, s3}` for the random generator.
    Default: `{1, 2, 3}`.
  - `:algorithm` - The random algorithm to use. Default: `:exsss`.
  - `:output` - optional output transform function.
  - `:suspend` - optional suspend transform function.

  ## Example

      comp do
        a <- Random.random()
        b <- Random.random_int(1, 10)
        {a, b}
      end
      |> Random.Seed.with_handler(seed: {42, 42, 42})
      |> Comp.run!()
      #=> {0.123..., 7}  # always the same with this seed
  """
  @spec with_handler(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def with_handler(comp, opts \\ []) do
    seed = Keyword.get(opts, :seed, {1, 2, 3})
    algorithm = Keyword.get(opts, :algorithm, :exsss)
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)

    initial_rand_state = :rand.seed_s(algorithm, seed)
    initial_state = %State{rand_state: initial_rand_state}

    scoped_opts =
      []
      |> then(fn o -> if output, do: Keyword.put(o, :output, output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    comp
    |> Comp.with_scoped_state(@sig, initial_state, scoped_opts)
    |> Comp.with_handler(@sig, &handle/3)
  end

  @impl Skuld.Comp.IInstall
  def __handle__(comp, opts) when is_list(opts), do: with_handler(comp, opts)
  def __handle__(comp, _config), do: with_handler(comp)

  @impl Skuld.Comp.IHandle
  def handle(%RandomFloat{}, env, k) do
    %State{rand_state: rand_state} = Env.get_state(env, @sig)
    {value, new_rand_state} = :rand.uniform_s(rand_state)
    new_env = Env.put_state(env, @sig, %State{rand_state: new_rand_state})
    k.(value, new_env)
  end

  def handle(%RandomInt{min: min, max: max}, env, k) do
    %State{rand_state: rand_state} = Env.get_state(env, @sig)
    {raw, new_rand_state} = :rand.uniform_s(max - min + 1, rand_state)
    value = min + raw - 1
    new_env = Env.put_state(env, @sig, %State{rand_state: new_rand_state})
    k.(value, new_env)
  end

  def handle(%RandomElement{list: list}, env, k) do
    %State{rand_state: rand_state} = Env.get_state(env, @sig)
    {raw, new_rand_state} = :rand.uniform_s(length(list), rand_state)
    index = raw - 1
    new_env = Env.put_state(env, @sig, %State{rand_state: new_rand_state})
    k.(Enum.at(list, index), new_env)
  end

  def handle(%Shuffle{list: list}, env, k) do
    # Fisher-Yates shuffle with explicit state threading
    %State{rand_state: rand_state} = Env.get_state(env, @sig)
    {shuffled, new_rand_state} = shuffle_with_state(list, rand_state)
    new_env = Env.put_state(env, @sig, %State{rand_state: new_rand_state})
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
end
