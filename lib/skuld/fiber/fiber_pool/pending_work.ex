defmodule Skuld.Fiber.FiberPool.PendingWork do
  @moduledoc """
  Fiber-local accumulations of pending fibers and tasks.

  This struct consolidates the loose keys that were previously stored
  separately in `env.state` for tracking work to be scheduled:

  - `fibers` - Fibers spawned by `FiberPool.fiber()` waiting to be scheduled
  - `tasks` - Tasks spawned by `FiberPool.task()` waiting to be spawned

  ## Lifecycle

  Unlike `EnvState` which is shared across all fibers, `PendingWork` is
  fiber-local. It's accumulated during fiber execution via effect handlers,
  then extracted and cleared by FiberPool.run and Scheduler:

  1. Fiber calls `FiberPool.fiber(comp)` → handler adds to `fibers`
  2. Fiber calls `FiberPool.task(thunk)` → handler adds to `tasks`
  3. Fiber step completes → Scheduler extracts pending work
  4. PendingWork is cleared before seeding env to next fiber

  This is managed via `Comp.with_scoped_state` for proper scoping.

  ## Key

  Use `env_key/0` to get the key under which this struct is stored in env.state.
  """

  alias Skuld.Fiber

  @doc """
  The key under which PendingWork is stored in env.state.
  """
  @spec env_key() :: module()
  def env_key, do: __MODULE__

  @type fiber_id :: reference()
  @type task_info :: {fiber_id(), (-> term()), keyword()}

  @type t :: %__MODULE__{
          fibers: [{fiber_id(), Fiber.t()}],
          tasks: [task_info()]
        }

  defstruct fibers: [],
            tasks: []

  @doc """
  Create a new empty PendingWork.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  #############################################################################
  ## Fiber Management
  #############################################################################

  @doc """
  Add a fiber to pending work. Called by FiberPool.fiber() handler.
  """
  @spec add_fiber(t(), fiber_id(), Fiber.t()) :: t()
  def add_fiber(%__MODULE__{fibers: fibers} = pending, fiber_id, fiber) do
    %{pending | fibers: [{fiber_id, fiber} | fibers]}
  end

  @doc """
  Take all pending fibers, returning them and an updated PendingWork with empty fibers.
  """
  @spec take_fibers(t()) :: {[{fiber_id(), Fiber.t()}], t()}
  def take_fibers(%__MODULE__{fibers: fibers} = pending) do
    {fibers, %{pending | fibers: []}}
  end

  @doc """
  Check if there are pending fibers.
  """
  @spec has_fibers?(t()) :: boolean()
  def has_fibers?(%__MODULE__{fibers: []}), do: false
  def has_fibers?(%__MODULE__{}), do: true

  #############################################################################
  ## Task Management
  #############################################################################

  @doc """
  Add a task to pending work. Called by FiberPool.task() handler.
  """
  @spec add_task(t(), task_info()) :: t()
  def add_task(%__MODULE__{tasks: tasks} = pending, task_info) do
    %{pending | tasks: [task_info | tasks]}
  end

  @doc """
  Take all pending tasks, returning them and an updated PendingWork with empty tasks.
  """
  @spec take_tasks(t()) :: {[task_info()], t()}
  def take_tasks(%__MODULE__{tasks: tasks} = pending) do
    {tasks, %{pending | tasks: []}}
  end

  @doc """
  Check if there are pending tasks.
  """
  @spec has_tasks?(t()) :: boolean()
  def has_tasks?(%__MODULE__{tasks: []}), do: false
  def has_tasks?(%__MODULE__{}), do: true

  #############################################################################
  ## Combined Operations
  #############################################################################

  @doc """
  Check if there is any pending work (fibers or tasks).
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{fibers: [], tasks: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Take all pending work, returning fibers, tasks, and an empty PendingWork.
  """
  @spec take_all(t()) :: {[{fiber_id(), Fiber.t()}], [task_info()], t()}
  def take_all(%__MODULE__{fibers: fibers, tasks: tasks}) do
    {fibers, tasks, %__MODULE__{}}
  end
end
