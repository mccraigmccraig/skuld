defmodule Skuld.Effects.FreshInt do
  @moduledoc """
  FreshInt effect — generate monotonically increasing integers.

  Zero dependencies. The handler stores a seed value in env state,
  returns it, and increments. Both test and production handlers use
  the same counter implementation — deterministic by default, no
  external library needed.

  ## Production Usage

      comp do
        id <- FreshInt.fresh_integer()
        id
      end
      |> FreshInt.with_handler()
      |> Comp.run!()
      #=> 0

  ## Test Usage (Deterministic)

      comp do
        id <- FreshInt.fresh_integer()
        id
      end
      |> FreshInt.with_handler(seed: 100)
      |> Comp.run!()
      #=> 100  (deterministic, reproducible)
  """

  @behaviour Skuld.Comp.IInstall

  use Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operations
  #############################################################################

  def_op(fresh_integer())

  @doc false
  @spec fresh_integer_op() :: atom()
  def fresh_integer_op, do: @__fresh_integer_op__

  #############################################################################
  ## State
  #############################################################################

  defmodule State do
    @moduledoc false
    defstruct [:counter]
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a FreshInt handler.

  ## Options

  - `:seed` — starting integer value (default: 0)
  """
  @spec with_handler(Types.computation(), keyword()) :: Types.computation()
  def with_handler(comp, opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)

    comp
    |> Comp.with_scoped_state(@sig, %State{counter: seed})
    |> Comp.with_new_handler(@sig, &handle/3)
  end

  #############################################################################
  ## Handler
  #############################################################################

  @doc false
  def handle(@__fresh_integer_op__, env, k) do
    state = Env.get_state!(env, @sig)
    counter = state.counter
    new_env = Env.put_state(env, @sig, %{state | counter: counter + 1})
    k.(counter, new_env)
  end

  #############################################################################
  ## Catch Clause
  #############################################################################

  @impl Skuld.Comp.IInstall
  def __handle__(comp, opts) when is_list(opts), do: with_handler(comp, opts)
  def __handle__(comp, _config), do: with_handler(comp)
end
