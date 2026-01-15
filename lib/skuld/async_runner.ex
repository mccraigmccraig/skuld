defmodule Skuld.AsyncRunner do
  @moduledoc """
  Run a computation in a separate process, bridging yields, throws, and results
  back to the calling process via messages.

  This is for running effectful computations from non-effectful code (e.g., LiveView).
  If you're inside a computation and want concurrency, use `Skuld.Effects.Async` instead.

  ## Messages

  The runner sends messages to the caller in the form `{tag, status, value}`:

  - `{tag, :yield, value}` - computation yielded, waiting for resume
  - `{tag, :result, value}` - computation completed successfully
  - `{tag, :throw, error}` - computation threw an error
  - `{tag, :stopped, reason}` - computation was cancelled/stopped

  ## Example

      # Build computation with handlers
      computation =
        comp do
          result <- Command.execute(%CreateTodo{title: "Buy milk"})
          result
        end
        |> Command.with_handler(&DomainHandler.handle/1)
        |> Reader.with_handler(context, tag: CommandContext)
        |> EctoPersist.with_handler(Repo)

      # Start async - will add Yield and Throw handlers
      {:ok, runner} = AsyncRunner.start(computation, tag: :create_todo)

      # In handle_info:
      def handle_info({:create_todo, :result, {:ok, todo}}, socket) do
        {:noreply, handle_success(socket, todo)}
      end

      def handle_info({:create_todo, :throw, error}, socket) do
        {:noreply, handle_error(socket, error)}
      end

  ## With Yields

      # Computation that yields for user input
      computation =
        comp do
          name <- Yield.yield(:get_name)
          email <- Yield.yield(:get_email)
          create_user(name, email)
        end
        |> ...handlers...

      {:ok, runner} = AsyncRunner.start(computation, tag: :create_user)

      # Handle yields
      def handle_info({:create_user, :yield, :get_name}, socket) do
        # Maybe wait for user input, then:
        AsyncRunner.resume(runner, "Alice")
        {:noreply, socket}
      end

      def handle_info({:create_user, :yield, :get_email}, socket) do
        AsyncRunner.resume(runner, "alice@example.com")
        {:noreply, socket}
      end

      def handle_info({:create_user, :result, {:ok, user}}, socket) do
        {:noreply, assign(socket, user: user)}
      end
  """

  alias Skuld.Effects.{Yield, Throw}

  defstruct [:tag, :ref, :pid, :monitor_ref, :caller]

  @type t :: %__MODULE__{
          tag: term(),
          ref: reference(),
          pid: pid(),
          monitor_ref: reference(),
          caller: pid()
        }

  @doc """
  Start a computation in a separate process.

  The computation will have `Throw.with_handler/1` and `Yield.with_handler/1`
  added automatically (outermost). Add your other handlers before calling start.

  ## Options

  - `:tag` - Required. Tag for messages, e.g. `:create_todo`
  - `:caller` - Process to send messages to (default: `self()`)
  - `:link` - Whether to link the runner process (default: `true`)

  ## Returns

  `{:ok, runner}` where runner is used with `resume/2` and `cancel/1`.
  """
  @spec start(Skuld.Comp.Types.computation(), keyword()) :: {:ok, t()}
  def start(computation, opts) do
    tag = Keyword.fetch!(opts, :tag)
    caller = Keyword.get(opts, :caller, self())
    link? = Keyword.get(opts, :link, true)
    ref = make_ref()

    spawn_fn = if link?, do: &spawn_link/1, else: &spawn/1

    pid =
      spawn_fn.(fn ->
        run_bridged(computation, caller, tag, ref)
      end)

    monitor_ref = Process.monitor(pid)

    {:ok, %__MODULE__{tag: tag, ref: ref, pid: pid, monitor_ref: monitor_ref, caller: caller}}
  end

  @doc """
  Resume a yielded computation with a value.

  Call this after receiving a `{tag, :yield, value}` message.
  """
  @spec resume(t(), term()) :: :ok
  def resume(%__MODULE__{ref: ref, pid: pid}, value) do
    send(pid, {:async_resume, ref, value})
    :ok
  end

  @doc """
  Cancel a running computation.

  The computation process will be terminated and a `{tag, :stopped, :cancelled}`
  message will be sent to the caller.
  """
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{ref: ref, pid: pid, monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    send(pid, {:async_cancel, ref})
    :ok
  end

  # Child process entry point
  defp run_bridged(computation, caller, tag, ref) do
    # Add Yield and Throw handlers on top of user's handlers
    comp =
      computation
      |> Throw.with_handler()
      |> Yield.with_handler()

    # Run with a driver that bridges messages to the caller
    result =
      Yield.run_with_driver(comp, fn yielded_value ->
        send(caller, {tag, :yield, yielded_value})

        receive do
          {:async_resume, ^ref, value} -> {:continue, value}
          {:async_cancel, ^ref} -> {:stop, :cancelled}
        end
      end)

    # Send final result
    case result do
      {:done, value, _env} ->
        send(caller, {tag, :result, value})

      {:stopped, reason, _env} ->
        send(caller, {tag, :stopped, reason})

      {:thrown, error, _env} ->
        send(caller, {tag, :throw, error})
    end
  end
end
