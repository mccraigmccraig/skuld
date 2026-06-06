# Fixed value random handler for Random effect - for testing specific scenarios.
#
# Returns values from a fixed sequence, cycling when exhausted.
# Useful for testing specific scenarios where you need exact control
# over random values.
#
# ## Example
#
#     comp do
#       a <- Random.random()
#       b <- Random.random()
#       c <- Random.random()
#       {a, b, c}
#     end
#     |> Random.Fixed.with_handler(values: [0.1, 0.5, 0.9])
#     |> Comp.run!()
#     #=> {0.1, 0.5, 0.9}
#
#     # Cycles when exhausted
#     comp do
#       a <- Random.random()
#       b <- Random.random()
#       c <- Random.random()
#       d <- Random.random()
#       {a, b, c, d}
#     end
#     |> Random.Fixed.with_handler(values: [0.0, 1.0])
#     |> Comp.run!()
#     #=> {0.0, 1.0, 0.0, 1.0}
defmodule Skuld.Effects.Random.Fixed do
  @moduledoc false

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Effects.Random

  @sig Random.sig()
  @random_op Random.random_op()
  @random_int_op Random.random_int_op()
  @random_element_op Random.random_element_op()
  @shuffle_op Random.shuffle_op()

  defmodule State do
    @moduledoc false
    defstruct values: [], original: []
  end

  @doc """
  Install a handler that returns values from a fixed sequence.

  ## Options

  - `:values` - A list of values to return. For `random()` these should
    be floats 0.0-1.0. For `random_int/2` and `random_element/1`, the
    handler uses these as indices (mod list length).
  - `:output` - optional output transform function.
  - `:suspend` - optional suspend transform function.

  ## Example

      comp do
        a <- Random.random()
        b <- Random.random()
        c <- Random.random()
        {a, b, c}
      end
      |> Random.Fixed.with_handler(values: [0.1, 0.5, 0.9])
      |> Comp.run!()
      #=> {0.1, 0.5, 0.9}
  """
  @spec with_handler(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def with_handler(comp, opts \\ []) do
    values = Keyword.get(opts, :values, [0.5])
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)

    initial_state = %State{values: values, original: values}

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
  def handle(@random_op, env, k) do
    {value, new_env} = next_fixed_value(env)
    k.(value, new_env)
  end

  def handle({@random_int_op, min, max}, env, k) do
    {raw, new_env} = next_fixed_value(env)
    # Interpret raw as a position in the range
    range_size = max - min + 1
    value = (min + trunc(raw * range_size)) |> min(max)
    k.(value, new_env)
  end

  def handle({@random_element_op, list}, env, k) do
    {raw, new_env} = next_fixed_value(env)
    index = trunc(raw * length(list)) |> min(length(list) - 1)
    k.(Enum.at(list, index), new_env)
  end

  def handle({@shuffle_op, list}, env, k) do
    # For fixed handler, just reverse the list as a deterministic "shuffle"
    # (Real shuffle would need multiple values)
    k.(Enum.reverse(list), env)
  end

  defp next_fixed_value(env) do
    state = Env.get_state!(env, @sig)

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
end
