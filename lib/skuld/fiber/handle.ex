defmodule Skuld.Fiber.Handle do
  @moduledoc """
  Opaque handle for referencing a fiber submitted to a FiberPool.

  Users receive a Handle when they submit a computation to the FiberPool.
  The handle can be used to await the fiber's result or cancel it.

  Handles are opaque - users cannot access the underlying fiber state directly.
  All operations go through the FiberPool.

  ## Example

      comp do
        handle <- FiberPool.fiber(my_computation)
        # ... do other work ...
        result <- FiberPool.await!(handle)
        result
      end
  """

  @type t :: %__MODULE__{
          id: reference(),
          pool_id: reference()
        }

  @enforce_keys [:id, :pool_id]
  defstruct [:id, :pool_id]

  @doc """
  Create a new handle for a fiber.

  This is called internally by FiberPool when a fiber is submitted.
  Users should not create handles directly.

  ## Parameters

  - `fiber_id` - The fiber's unique identifier (reference)
  - `pool_id` - The FiberPool's unique identifier (reference)
  """
  @spec new(reference(), reference()) :: t()
  def new(fiber_id, pool_id) when is_reference(fiber_id) and is_reference(pool_id) do
    %__MODULE__{id: fiber_id, pool_id: pool_id}
  end

  @doc """
  Get the fiber ID from a handle.

  Used internally by FiberPool to look up the fiber.
  """
  @spec fiber_id(t()) :: reference()
  def fiber_id(%__MODULE__{id: id}), do: id

  @doc """
  Get the pool ID from a handle.

  Used to verify a handle belongs to the expected pool.
  """
  @spec pool_id(t()) :: reference()
  def pool_id(%__MODULE__{pool_id: pool_id}), do: pool_id
end
