defmodule Skuld.Effects.Async.Scheduler.Server do
  @moduledoc """
  GenServer wrapper for the cooperative scheduler.

  Provides a long-lived scheduler process that can receive completion messages
  and spawn new computations dynamically.

  ## Usage

  ```elixir
  # Start with initial computations
  {:ok, server} = Scheduler.Server.start_link(
    computations: [workflow(user1), workflow(user2)],
    scheduler_opts: [on_error: :log_and_continue]
  )

  # Spawn additional computations
  {:ok, tag} = Scheduler.Server.spawn(server, workflow(user3))

  # Check status
  stats = Scheduler.Server.stats(server)
  # => %{suspended: 2, ready: 0, completed: 1}

  # Get a completed result
  {:ok, result} = Scheduler.Server.get_result(server, tag)

  # Stop the server
  :ok = Scheduler.Server.stop(server)
  ```

  ## How It Works

  The server maintains scheduler state and processes messages:

  1. Completion messages (`{ref, result}`, `{:DOWN, ...}`, etc.) arrive via `handle_info`
  2. Each message is matched and updates the scheduler state
  3. Ready computations are drained from the run queue
  4. New computations can be spawned via `spawn/2` or `spawn/3`

  ## Supervision

  The server can be added to a supervision tree:

  ```elixir
  children = [
    {Scheduler.Server, name: MyApp.Scheduler, computations: initial_comps}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
  ```
  """

  use GenServer

  require Logger

  alias Skuld.Effects.Async.Scheduler
  alias Skuld.Effects.Async.Scheduler.State

  @type server :: GenServer.server()
  @type tag :: reference() | term()

  #############################################################################
  ## Client API
  #############################################################################

  @doc """
  Start a scheduler server.

  ## Options

  - `:computations` - List of initial computations to run (default: `[]`)
  - `:scheduler_opts` - Options passed to `Scheduler.State.new/1` (default: `[]`)
  - `:name` - GenServer name registration (optional)

  All other options are passed to `GenServer.start_link/3`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {computations, opts} = Keyword.pop(opts, :computations, [])
    {scheduler_opts, opts} = Keyword.pop(opts, :scheduler_opts, [])

    init_arg = %{
      computations: computations,
      scheduler_opts: scheduler_opts
    }

    GenServer.start_link(__MODULE__, init_arg, opts)
  end

  @doc """
  Spawn a computation into the scheduler.

  Returns `{:ok, tag}` where `tag` can be used to retrieve the result later,
  or `{:error, reason}` if the computation failed immediately (with `:on_error => :stop`).
  """
  @spec spawn(server(), Scheduler.computation()) :: {:ok, tag()} | {:error, term()}
  def spawn(server, comp) do
    GenServer.call(server, {:spawn, comp})
  end

  @doc """
  Spawn a computation with a specific tag.

  The tag is used to identify the computation's result in `get_result/2`.
  """
  @spec spawn(server(), Scheduler.computation(), tag()) :: {:ok, tag()} | {:error, term()}
  def spawn(server, comp, tag) do
    GenServer.call(server, {:spawn, comp, tag})
  end

  @doc """
  Get scheduler statistics.

  Returns a map with:
  - `:suspended` - Number of computations waiting for completions
  - `:ready` - Number of computations in the run queue
  - `:completed` - Number of completed computations
  """
  @spec stats(server()) :: %{
          suspended: non_neg_integer(),
          ready: non_neg_integer(),
          completed: non_neg_integer()
        }
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Get the result of a completed computation.

  Returns `{:ok, result}` if the computation completed, `{:pending, state}` if
  still running (state is `:suspended` or `:ready`), or `{:error, :not_found}`
  if the tag is unknown.
  """
  @spec get_result(server(), tag()) ::
          {:ok, term()} | {:pending, :suspended | :ready} | {:error, :not_found}
  def get_result(server, tag) do
    GenServer.call(server, {:get_result, tag})
  end

  @doc """
  Get all completed results.

  Returns a map of `tag => result` for all completed computations.
  """
  @spec get_all_results(server()) :: %{tag() => term()}
  def get_all_results(server) do
    GenServer.call(server, :get_all_results)
  end

  @doc """
  Check if the scheduler is active (has suspended or ready computations).
  """
  @spec active?(server()) :: boolean()
  def active?(server) do
    GenServer.call(server, :active?)
  end

  @doc """
  Stop the scheduler server.
  """
  @spec stop(server(), term(), timeout()) :: :ok
  def stop(server, reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop(server, reason, timeout)
  end

  #############################################################################
  ## GenServer Callbacks
  #############################################################################

  @impl GenServer
  def init(%{computations: computations, scheduler_opts: scheduler_opts}) do
    state = State.new(scheduler_opts)

    # Spawn initial computations
    state =
      Enum.reduce(computations, state, fn comp, acc ->
        case Scheduler.spawn_into(acc, comp) do
          {:ok, _tag, new_state} ->
            new_state

          {:error, reason} ->
            Logger.error("Failed to spawn initial computation: #{inspect(reason)}")
            acc
        end
      end)

    # Drain any immediately ready computations
    state = drain_ready_state(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:spawn, comp}, _from, state) do
    case Scheduler.spawn_into(state, comp) do
      {:ok, tag, state} ->
        state = drain_ready_state(state)
        {:reply, {:ok, tag}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:spawn, comp, tag}, _from, state) do
    case Scheduler.spawn_into(state, comp, tag) do
      {:ok, ^tag, state} ->
        state = drain_ready_state(state)
        {:reply, {:ok, tag}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply, State.counts(state), state}
  end

  def handle_call({:get_result, tag}, _from, state) do
    result =
      case Map.get(state.completed, tag) do
        nil ->
          # Check if it's pending (tag association exists)
          pending_tag =
            Enum.find_value(state.completed, fn
              {_k, {:pending, ^tag}} -> true
              {_k, {:tag, ^tag}} -> true
              _ -> nil
            end)

          if pending_tag do
            {:pending, :suspended}
          else
            # Check if in run queue
            in_queue =
              state.run_queue
              |> :queue.to_list()
              |> Enum.any?(fn {req_id, _resume, _results} ->
                Map.get(state.completed, req_id) in [{:pending, tag}, {:tag, tag}]
              end)

            if in_queue do
              {:pending, :ready}
            else
              {:error, :not_found}
            end
          end

        {:pending, _} ->
          {:pending, :suspended}

        {:tag, _} ->
          {:pending, :suspended}

        result ->
          {:ok, result}
      end

    {:reply, result, state}
  end

  def handle_call(:get_all_results, _from, state) do
    # Filter out pending markers and tag associations
    results =
      state.completed
      |> Enum.reject(fn
        {_k, {:pending, _}} -> true
        {_k, {:tag, _}} -> true
        _ -> false
      end)
      |> Map.new()

    {:reply, results, state}
  end

  def handle_call(:active?, _from, state) do
    {:reply, State.active?(state), state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    case Scheduler.handle_message(state, msg) do
      {:ok, state} ->
        state = drain_ready_state(state)
        {:noreply, state}

      {:ignored, state} ->
        Logger.debug("Scheduler.Server received unrecognized message: #{inspect(msg)}")
        {:noreply, state}
    end
  end

  #############################################################################
  ## Private Helpers
  #############################################################################

  defp drain_ready_state(state) do
    case Scheduler.drain_ready(state) do
      {:idle, state} ->
        state

      {:done, state} ->
        state

      {:error, reason} ->
        Logger.error("Scheduler error while draining: #{inspect(reason)}")
        state
    end
  end
end
