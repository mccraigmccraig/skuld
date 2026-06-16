defmodule Skuld.PageMachine.Spindle do
  @moduledoc """
  Named concurrent sub-computations (spindles) that run as fibers within
  a FiberPool. Each spindle is identified by an atom key and communicates
  results through auto-tagged yields.

  ## Usage

      use Skuld.Syntax

      comp do
        checkout <- Spindle.fork(:checkout, MyApp.CheckoutFlow.flow(product))

        # Main spindle continues...
        filters <- Yield.yield(:search)
        {:ok, results} <- MyApp.ProductCatalog.search(filters)
        Yield.yield({:results, results})
      end
      |> Spindle.with_handler()
      |> FiberYield.with_handler()
      |> FiberPool.with_handler()
      |> Comp.run()
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Effects.FiberPool

  @sig __MODULE__

  @ids_by_key_key Module.concat(__MODULE__, IdsByKey)
  @keys_by_id_key Module.concat(__MODULE__, KeysById)

  @doc "Every state key for spindle_key -> fiber_id mappings."
  def ids_by_key_key, do: @ids_by_key_key

  @doc "Environment state key for fiber_id -> spindle_key mappings."
  def keys_by_id_key, do: @keys_by_id_key

  #############################################################################
  ## Public API
  #############################################################################

  @doc """
  Fork a named spindle as a FiberPool fiber.

  Returns a Handle that can be used with `FiberPool.await!/1`.
  """
  @spec fork(atom(), Types.computation()) :: Types.computation()
  def fork(key, computation) when is_atom(key) do
    Comp.effect(@sig, {:fork, key, computation})
  end

  @doc """
  Install the Spindle handler. Must be installed outside `FiberPool.with_handler/1`
  in the handler chain.
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(computation) do
    Comp.with_handler(computation, @sig, &handle/3)
  end

  #############################################################################
  ## Handler Implementation
  #############################################################################

  @doc false
  def handle({:fork, key, computation}, env, k) do
    wrapped_k = fn handle, fiber_env ->
      ids_by_key = Env.get_state(fiber_env, @ids_by_key_key, %{})
      keys_by_id = Env.get_state(fiber_env, @keys_by_id_key, %{})

      next_env =
        fiber_env
        |> Env.put_state(@ids_by_key_key, Map.put(ids_by_key, key, handle.id))
        |> Env.put_state(@keys_by_id_key, Map.put(keys_by_id, handle.id, key))

      k.(handle, next_env)
    end

    fiber_effect = FiberPool.fiber(computation)
    Comp.call(fiber_effect, env, wrapped_k)
  end
end
