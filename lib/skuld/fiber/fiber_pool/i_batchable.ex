# Protocol for effect operations that can be batched together.
#
# Operations with the same `batch_key` are grouped and executed together by
# the FiberPool scheduler. This enables automatic I/O batching - multiple
# fibers requesting the same type of data have their requests combined into
# a single batch operation.
#
# ## Implementing IBatchable
#
# To make an operation batchable, implement the `batch_key/1` function to
# return a key that identifies the batch group:
#
#     defimpl Skuld.Fiber.FiberPool.IBatchable, for: MyApp.DB.Fetch do
#       def batch_key(%{schema: schema}), do: {:db_fetch, schema}
#     end
#
# Operations with the same batch_key will be grouped together. The batch_key
# can be any term - tuples are common for hierarchical grouping.
#
# ## Non-Batchable Operations
#
# Return `nil` from `batch_key/1` to indicate an operation should not be
# batched. The default implementation (for Any) returns `nil`.
#
# ## Batch Execution
#
# Batch execution is NOT part of this protocol. Executors are installed
# per-scope via `BatchExecutor.with_executor/3`, allowing different
# execution strategies in different contexts (test vs prod, different
# repos, etc.).
defprotocol Skuld.Fiber.FiberPool.IBatchable do
  @moduledoc false

  @doc """
  Returns the batch key for grouping this operation, or nil if not batchable.

  Operations with the same batch_key will be grouped and executed together.
  """
  @spec batch_key(t) :: term() | nil
  def batch_key(op)
end

# Fallback - operations are not batchable by default
defimpl Skuld.Fiber.FiberPool.IBatchable, for: Any do
  def batch_key(_op), do: nil
end
