defmodule Skuld.Effects.TaggedState do
  @moduledoc """
  Tagged State effect - multiple independent mutable state values.

  Like `State`, but allows multiple independent state values identified by tags.

  ## Example

      alias Skuld.Comp
      alias Skuld.Effects.TaggedState

      comp do
        _ <- TaggedState.put(:counter, 0)
        _ <- TaggedState.modify(:counter, &(&1 + 1))
        _ <- TaggedState.modify(:counter, &(&1 + 1))
        count <- TaggedState.get(:counter)
        _ <- TaggedState.put(:result, count * 10)
        result <- TaggedState.get(:result)
        return({count, result})
      end
      |> TaggedState.with_handler(:counter, 0)
      |> TaggedState.with_handler(:result, nil)
      |> Comp.run!()

      # => {2, 20}
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Data.Change

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Get, [:tag])
  def_op(Put, [:tag, :value])

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Get the current state for the given tag"
  @spec get(atom()) :: Types.computation()
  def get(tag) do
    Comp.effect(@sig, %Get{tag: tag})
  end

  @doc "Replace the state for the given tag, returning `%Change{old: old_state, new: new_state}`"
  @spec put(atom(), term()) :: Types.computation()
  def put(tag, value) do
    Comp.effect(@sig, %Put{tag: tag, value: value})
  end

  @doc "Modify the state for the given tag with a function, returning the old value"
  @spec modify(atom(), (term() -> term())) :: Types.computation()
  def modify(tag, f) do
    Comp.bind(get(tag), fn old ->
      Comp.bind(put(tag, f.(old)), fn _ ->
        Comp.pure(old)
      end)
    end)
  end

  @doc "Get a value derived from the state for the given tag"
  @spec gets(atom(), (term() -> term())) :: Types.computation()
  def gets(tag, f) do
    Comp.map(get(tag), f)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped TaggedState handler for a computation with the given tag.

  Multiple TaggedState handlers with different tags can be installed simultaneously.

  ## Options

  - `output` - optional function `(result, final_state) -> new_result`
    to transform the result before returning. Useful for including the final
    state in the output.

  ## Example

      comp do
        x <- TaggedState.get(:counter)
        _ <- TaggedState.put(:counter, x + 1)
        _ <- TaggedState.put(:name, "alice")
        return(x)
      end
      |> TaggedState.with_handler(:counter, 0)
      |> TaggedState.with_handler(:name, "")
      |> Comp.run()

      # Include final state in result
      comp do
        _ <- TaggedState.modify(:counter, &(&1 + 1))
        return(:done)
      end
      |> TaggedState.with_handler(:counter, 0, output: fn r, s -> {r, s} end)
      |> Comp.run!()
      # => {:done, 1}
  """
  @spec with_handler(Types.computation(), atom(), term(), keyword()) :: Types.computation()
  def with_handler(comp, tag, initial, opts \\ []) do
    state_key = state_key(tag)
    output = Keyword.get(opts, :output)

    comp
    |> Comp.scoped(fn env ->
      previous = Env.get_state(env, state_key)
      modified = Env.put_state(env, state_key, initial)

      finally_k = fn value, e ->
        final_state = Env.get_state(e, state_key)

        restored_env =
          case previous do
            nil -> %{e | state: Map.delete(e.state, state_key)}
            val -> Env.put_state(e, state_key, val)
          end

        transformed_value =
          if output do
            output.(value, final_state)
          else
            value
          end

        {transformed_value, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  @doc "Extract the state for the given tag from an env"
  @spec get_state(Types.env(), atom()) :: term()
  def get_state(env, tag) do
    Env.get_state(env, state_key(tag))
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(%Get{tag: tag}, env, k) do
    value = Env.get_state(env, state_key(tag))
    k.(value, env)
  end

  @impl Skuld.Comp.IHandler
  def handle(%Put{tag: tag, value: value}, env, k) do
    old_value = Env.get_state(env, state_key(tag))
    new_env = Env.put_state(env, state_key(tag), value)
    k.(Change.new(old_value, value), new_env)
  end

  #############################################################################
  ## Private
  #############################################################################

  defp state_key(tag), do: {__MODULE__, tag}
end
