defmodule Skuld.Effects.Async.Await do
  @moduledoc """
  Low-level Await effect for cooperative multitasking.

  Yields `%AwaitSuspend{}` requests that schedulers handle internally.
  Higher-level effects like `Async` build on this.

  ## How It Works

  When `await/1` is called, the handler wraps the continuation in an
  `%AwaitSuspend{}` sentinel and returns it. The scheduler recognizes
  this sentinel and:

  1. Tracks the suspension with its request ID
  2. Waits for completion messages matching the request's targets
  3. Resumes the computation when wake conditions are met

  ## Example

      comp do
        task = Task.async(fn -> expensive_work() end)
        target = TaskTarget.new(task)
        request = AwaitRequest.new([target], :all)

        [result] <- Await.await(request)
        process(result)
      end
      |> Await.with_handler()
      |> Scheduler.run()

  ## Convenience Functions

  For simpler usage, `await_all/1` and `await_any/1` create the request
  automatically:

      # Wait for all targets
      results <- Await.await_all([TaskTarget.new(t1), TaskTarget.new(t2)])

      # Wait for any target (returns {winning_target, result})
      {winner, result} <- Await.await_any([TaskTarget.new(task), timer])
  """

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types
  alias Skuld.Effects.Async.AwaitRequest
  alias Skuld.Effects.Async.AwaitSuspend

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Await, [:request])

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Await an `AwaitRequest`.

  Returns a computation that yields `%AwaitSuspend{}` for the scheduler
  to handle.
  """
  @spec await(AwaitRequest.t()) :: Types.computation()
  def await(%AwaitRequest{} = request) do
    Comp.effect(@sig, %Await{request: request})
  end

  @doc """
  Await all targets, returning results in order.

  Creates an `:all` mode request and awaits it.
  """
  @spec await_all([AwaitRequest.target()]) :: Types.computation()
  def await_all(targets) when is_list(targets) do
    await(AwaitRequest.new(targets, :all))
  end

  @doc """
  Await any target, returning `{target, result}` for the first to complete.

  Creates an `:any` mode request and awaits it.
  """
  @spec await_any([AwaitRequest.target()]) :: Types.computation()
  def await_any(targets) when is_list(targets) do
    await(AwaitRequest.new(targets, :any))
  end

  #############################################################################
  ## Handler
  #############################################################################

  @doc """
  Install the Await handler.

  The handler wraps the continuation in `%AwaitSuspend{}`, which the
  scheduler will intercept and handle.
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, @sig, &handle/3)
  end

  defp handle(%Await{request: request}, env, k) do
    suspend = %AwaitSuspend{
      request: request,
      resume: fn results -> k.(results, env) end
    }

    {suspend, env}
  end
end
