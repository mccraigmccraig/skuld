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

  ## Handler Submodules

  - `Random.Seed` - Deterministic seeded random handler
  - `Random.Fixed` - Fixed value handler for testing
  """

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @sig __MODULE__

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
    Comp.with_handler(comp, @sig, &handle/3)
  end

  @impl Skuld.Comp.IHandle
  def handle(%RandomFloat{}, env, k) do
    k.(:rand.uniform(), env)
  end

  def handle(%RandomInt{min: min, max: max}, env, k) do
    # :rand.uniform(n) returns 1..n, so adjust for min..max range
    value = min + :rand.uniform(max - min + 1) - 1
    k.(value, env)
  end

  def handle(%RandomElement{list: list}, env, k) do
    index = :rand.uniform(length(list)) - 1
    k.(Enum.at(list, index), env)
  end

  def handle(%Shuffle{list: list}, env, k) do
    k.(Enum.shuffle(list), env)
  end

  #############################################################################
  ## Handler Delegation
  #############################################################################

  @doc """
  Install a deterministic random handler with a fixed seed.

  Delegates to `Random.Seed.with_handler/2`.

  ## Options

  - `:seed` - A seed tuple `{s1, s2, s3}` for the random generator.
    Default: `{1, 2, 3}`.
  - `:algorithm` - The random algorithm to use. Default: `:exsss`.

  ## Example

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
    __MODULE__.Seed.with_handler(comp, opts)
  end

  @doc """
  Install a handler that returns values from a fixed sequence.

  Delegates to `Random.Fixed.with_handler/2`.

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
  """
  @spec with_fixed_handler(Types.computation(), keyword()) :: Types.computation()
  def with_fixed_handler(comp, opts \\ []) do
    __MODULE__.Fixed.with_handler(comp, opts)
  end

  #############################################################################
  ## Catch Clause Installation
  #############################################################################

  @doc """
  Install Random handler via catch clause syntax.

  Config selects handler type:

      catch
        Random -> nil                            # production handler
        Random -> {:seed, seed: {1, 2, 3}}       # seeded handler
        Random -> {:fixed, values: [0.5, 0.7]}   # fixed values handler
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, nil), do: with_handler(comp)
  def __handle__(comp, :random), do: with_handler(comp)

  def __handle__(comp, {:seed, opts}) when is_list(opts),
    do: __MODULE__.Seed.__handle__(comp, opts)

  def __handle__(comp, {:fixed, opts}) when is_list(opts),
    do: __MODULE__.Fixed.__handle__(comp, opts)
end
