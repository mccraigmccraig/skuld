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
  alias Skuld.Effects.FiberYield

  @sig __MODULE__

  defmodule Mappings do
    @moduledoc false

    defstruct fiber_ids_by_spindle_key: %{}, spindle_keys_by_fiber_id: %{}

    @typedoc false
    @type t :: %__MODULE__{
            fiber_ids_by_spindle_key: %{atom() => term()},
            spindle_keys_by_fiber_id: %{term() => atom()}
          }

    @doc "Register a spindle key -> fiber_id pair in both maps."
    @spec register(t(), atom(), term()) :: t()
    def register(mappings, spindle_key, fiber_id) do
      %{
        mappings
        | fiber_ids_by_spindle_key:
            Map.put(mappings.fiber_ids_by_spindle_key, spindle_key, fiber_id),
          spindle_keys_by_fiber_id:
            Map.put(mappings.spindle_keys_by_fiber_id, fiber_id, spindle_key)
      }
    end

    @doc "Look up the spindle key for a given fiber ID."
    @spec spindle_key(t(), term()) :: atom() | nil
    def spindle_key(mappings, fiber_id) do
      Map.get(mappings.spindle_keys_by_fiber_id, fiber_id)
    end

    @doc "Look up the fiber ID for a given spindle key."
    @spec fiber_id(t(), atom()) :: reference() | nil
    def fiber_id(mappings, spindle_key) do
      Map.get(mappings.fiber_ids_by_spindle_key, spindle_key)
    end

    @doc "Merge another Mappings into this one."
    @spec merge(t(), t()) :: t()
    def merge(m1, m2) do
      %{
        m1
        | fiber_ids_by_spindle_key:
            Map.merge(m1.fiber_ids_by_spindle_key, m2.fiber_ids_by_spindle_key),
          spindle_keys_by_fiber_id:
            Map.merge(m1.spindle_keys_by_fiber_id, m2.spindle_keys_by_fiber_id)
      }
    end
  end

  @env_key Module.concat(__MODULE__, Mappings)

  @doc "Environment state key for %Spindle.Mappings{}."
  def env_key, do: @env_key

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
  Fire-and-forget notification to the PageMachine caller.

  Surfaces `value` to the caller (e.g., the LiveView) without pausing
  the spindle. The fiber continues immediately on the next scheduler
  round. Returns `nil` on resume.

  ## Example

      comp do
        Spindle.notify(:purchase_selected)
        # spindle continues immediately, no Yield.yield pause
        {:ok, results} <- MyApp.Catalog.search(filters)
        ...
      end
  """
  @spec notify(term()) :: Types.computation()
  def notify(value) do
    FiberYield.notify(value)
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
      mappings = Env.get_state(fiber_env, @env_key, %Mappings{})
      mappings = Mappings.register(mappings, key, handle.id)
      k.(handle, Env.put_state(fiber_env, @env_key, mappings))
    end

    fiber_effect = FiberPool.fiber(computation)
    Comp.call(fiber_effect, env, wrapped_k)
  end
end
