defmodule Skuld.Effects.Task do
  @moduledoc """
  Effect for BEAM Task-based parallelism within a FiberPool.

  Tasks run as separate BEAM processes, enabling true parallelism for
  CPU-bound work. The scheduler tracks them alongside cooperative fibers.

  Requires `FiberPool.with_handler/1` to be installed above this handler.

  ## Basic Usage

      comp do
        h <- Task.task(fn -> expensive_cpu_work() end)
        FiberPool.await!(h)
      end
      |> FiberPool.with_handler()
      |> Task.with_handler()
      |> Task.with_task_supervisor()
      |> Comp.run!()
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Fiber.Handle
  alias Skuld.FiberPool.PendingWork

  @sig __MODULE__

  #############################################################################
  ## Operations
  #############################################################################

  defmodule TaskOp do
    @moduledoc false
    defstruct [:thunk, :opts]
  end

  @task_supervisor_key {__MODULE__, :task_supervisor}

  #############################################################################
  ## Public API
  #############################################################################

  @doc """
  Run a thunk as a BEAM Task (parallel, separate process).

  The thunk runs in a separate BEAM process, allowing true parallelism
  for CPU-bound work. Returns a handle that can be awaited just like
  fiber handles.

  **Important:** The thunk is a zero-arity function, not a computation.
  Effects do not work inside tasks because they run in a different process.
  Extract any values you need from Reader/State before constructing the thunk.
  """
  @spec task((-> term()), keyword()) :: Comp.Types.computation()
  def task(thunk, opts \\ [])

  def task(thunk, opts) when is_function(thunk, 0) do
    Comp.effect(@sig, %TaskOp{thunk: thunk, opts: opts})
  end

  def task(thunk, _opts) when is_function(thunk, 2) do
    raise ArgumentError, """
    Task.task/2 requires a zero-arity thunk, but a 2-arity function (a computation) was given.

    Tasks run in a separate BEAM process, so effects (Reader, State, Writer, etc.)
    do not work inside them. Extract any values you need from the effect environment
    before constructing the thunk:

        config <- Reader.ask(:config)
        h <- Task.task(fn -> expensive_work(config) end)
    """
  end

  @doc false
  def task_supervisor_key, do: @task_supervisor_key

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install the Task handler, enabling `task/2` operations.

  Must be installed above the FiberPool handler:

      comp
      |> FiberPool.with_handler()
      |> Task.with_handler()
      |> Comp.run()
  """
  @spec with_handler(Comp.Types.computation()) :: Comp.Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, @sig, &handle/3)
  end

  @doc """
  Install a Task.Supervisor for BEAM task support.

  This starts a `Task.Supervisor` process before the computation runs and
  stops it after completion. Required for `task/2` — calling `task/2` without
  this will raise an error.

  ## Options

  - `:supervisor` - An existing `Task.Supervisor` pid to use instead of
    starting a new one. The caller is responsible for its lifecycle.
  """
  @spec with_task_supervisor(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def with_task_supervisor(comp, opts \\ []) do
    Comp.scoped(comp, fn env ->
      {sup, should_stop} =
        case Keyword.get(opts, :supervisor) do
          nil ->
            {:ok, sup} = Task.Supervisor.start_link()
            {sup, true}

          sup when is_pid(sup) ->
            {sup, false}
        end

      modified_env = Env.put_state(env, @task_supervisor_key, sup)

      finally_k = fn value, final_env ->
        if should_stop do
          Supervisor.stop(sup)
        end

        {value, final_env}
      end

      {modified_env, finally_k}
    end)
  end

  #############################################################################
  ## Handler Implementation
  #############################################################################

  defp handle(%TaskOp{thunk: thunk, opts: opts}, env, k) do
    unless Env.get_handler(env, Skuld.Effects.FiberPool) do
      raise ArgumentError, """
      Task.task/2 requires FiberPool.with_handler/1 to be installed.

      Wrap your computation with FiberPool.with_handler/1 before using tasks:

          comp
          |> FiberPool.with_handler()
          |> Task.with_handler()
          |> Task.with_task_supervisor()
          |> Comp.run()
      """
    end

    handle_id = make_ref()
    pool_id = Env.get_state(env, {Skuld.Effects.FiberPool, :pool_id}, make_ref())
    handle = Handle.new(handle_id, pool_id)

    pending_work = Env.get_state(env, PendingWork.env_key(), PendingWork.new())
    task_info = {handle_id, thunk, opts}
    pending_work = PendingWork.add_task(pending_work, task_info)
    env = Env.put_state(env, PendingWork.env_key(), pending_work)

    k.(handle, env)
  end
end
