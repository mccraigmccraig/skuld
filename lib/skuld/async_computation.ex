defmodule Skuld.AsyncComputation do
  @moduledoc """
  Run a computation in a separate process, bridging yields, throws, and results
  back to the calling process via messages.

  This is for running effectful computations from non-effectful code (e.g., LiveView).
  If you're inside a computation and want concurrency, use `Skuld.Effects.Async` instead.

  ## Messages

  The runner sends messages to the caller in the form `{tag, status, value}` or 
  `{tag, status, value, data}`:

  - `{tag, :yield, value, data}` - computation yielded, waiting for resume. `data` contains
    any decorations added by scoped effects (e.g., EffectLogger attaches its log here)
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
      {:ok, runner} = AsyncComputation.start(computation, tag: :create_todo)

      # Or start sync for fast-yielding computations
      {:ok, runner, {:yield, :ready}} = AsyncComputation.start_sync(computation, tag: :create_todo)

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

      {:ok, runner} = AsyncComputation.start(computation, tag: :create_user)

      # Handle yields (data contains any scoped effect decorations)
      def handle_info({:create_user, :yield, :get_name, _data}, socket) do
        # Maybe wait for user input, then:
        AsyncComputation.resume(runner, "Alice")
        {:noreply, socket}
      end

      def handle_info({:create_user, :yield, :get_email, _data}, socket) do
        AsyncComputation.resume(runner, "alice@example.com")
        {:noreply, socket}
      end

      def handle_info({:create_user, :result, {:ok, user}}, socket) do
        {:noreply, assign(socket, user: user)}
      end
  """

  alias Skuld.Effects.Throw
  alias Skuld.Effects.Yield

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
  Start a computation and wait synchronously for the first response.

  Use this when you know the computation will quickly yield after setup
  (e.g., a command processor that immediately yields waiting for commands).
  Avoids dealing with async messages for the initial handshake.

  ## Options

  Same as `start/2`, plus:

  - `:timeout` - Maximum time to wait in ms (default: 5000)

  ## Returns

  - `{:ok, runner, {:yield, value, data}}` - computation yielded, use runner to continue
  - `{:ok, runner, {:result, value}}` - computation completed immediately
  - `{:ok, runner, {:throw, error}}` - computation threw immediately
  - `{:ok, runner, {:stopped, reason}}` - computation stopped
  - `{:error, :timeout}` - timed out waiting for first response

  ## Example

      # Command processor that yields immediately for commands
      {:ok, runner, {:yield, :ready, _data}} =
        command_processor
        |> Reader.with_handler(context)
        |> AsyncComputation.start_sync(tag: :processor)

      # Now resume synchronously for quick commands
      {:yield, :ready, _data} = AsyncComputation.resume_sync(runner, %QuickCommand{})
  """
  @spec start_sync(Skuld.Comp.Types.computation(), keyword()) ::
          {:ok, t(),
           {:yield, term(), map() | nil}
           | {:result, term()}
           | {:throw, term()}
           | {:stopped, term()}}
          | {:error, :timeout}
  def start_sync(computation, opts) do
    timeout = Keyword.get(opts, :timeout, 5000)
    tag = Keyword.fetch!(opts, :tag)

    {:ok, runner} = start(computation, opts)

    receive do
      {^tag, :yield, yielded, data} -> {:ok, runner, {:yield, yielded, data}}
      {^tag, :result, result} -> {:ok, runner, {:result, result}}
      {^tag, :throw, error} -> {:ok, runner, {:throw, error}}
      {^tag, :stopped, reason} -> {:ok, runner, {:stopped, reason}}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Resume a yielded computation with a value (async).

  Call this after receiving a `{tag, :yield, value}` message.
  The next response will arrive via message to the caller (or `:reply_to` if specified).

  ## Options

  - `:reply_to` - Process to send the response to (default: original caller from start)
  """
  @spec resume(t(), term(), keyword()) :: :ok
  def resume(%__MODULE__{ref: ref, pid: pid}, value, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to)
    send(pid, {:async_resume, ref, value, reply_to})
    :ok
  end

  @doc """
  Resume a yielded computation and wait synchronously for the next response.

  Blocks until the computation yields again, completes, throws, or times out.

  This can be called from any process - the response will be sent to the calling
  process, not necessarily the original caller from `start/2`.

  ## Options

  - `:timeout` - Maximum time to wait in ms (default: 5000)

  ## Returns

  - `{:yield, value, data}` - computation yielded again
  - `{:result, value}` - computation completed
  - `{:throw, error}` - computation threw
  - `{:stopped, reason}` - computation was cancelled
  - `{:error, :timeout}` - timed out waiting for response

  ## Example

      {:ok, runner} = AsyncComputation.start(computation, tag: :cmd)

      # First yield arrives via message
      receive do
        {:cmd, :yield, :ready, _data} -> :ok
      end

      # Now resume and wait synchronously
      case AsyncComputation.resume_sync(runner, %SomeCommand{}) do
        {:yield, :ready, _data} -> # ready for next command
        {:result, final} -> # computation finished
        {:throw, error} -> # something went wrong
      end
  """
  @spec resume_sync(t(), term(), keyword()) ::
          {:yield, term(), map() | nil}
          | {:result, term()}
          | {:throw, term()}
          | {:stopped, term()}
          | {:error, :timeout}
  def resume_sync(%__MODULE__{ref: ref, pid: pid, tag: tag}, value, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    # Send self() as reply_to so response comes back to us, not original caller
    send(pid, {:async_resume, ref, value, self()})

    receive do
      {^tag, :yield, yielded, data} -> {:yield, yielded, data}
      {^tag, :result, result} -> {:result, result}
      {^tag, :throw, error} -> {:throw, error}
      {^tag, :stopped, reason} -> {:stopped, reason}
    after
      timeout -> {:error, :timeout}
    end
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

    # Track the current reply_to (can be overridden per-resume)
    # Start with the original caller
    reply_to_ref = make_ref()
    Process.put(reply_to_ref, caller)

    # Run with a driver that bridges messages to the caller (or reply_to override)
    result =
      Yield.run_with_driver(comp, fn yielded_value, data ->
        current_reply_to = Process.get(reply_to_ref)
        send(current_reply_to, {tag, :yield, yielded_value, data})

        # Reset to original caller after sending - any override only affects ONE yield
        Process.put(reply_to_ref, caller)

        receive do
          {:async_resume, ^ref, value, nil} ->
            # No override - keep using caller for next yield
            {:continue, value}

          {:async_resume, ^ref, value, override_reply_to} ->
            # Override for NEXT yield only (will be reset after that yield)
            Process.put(reply_to_ref, override_reply_to)
            {:continue, value}

          {:async_cancel, ^ref} ->
            {:stop, :cancelled}
        end
      end)

    # Send final result to current reply_to
    final_reply_to = Process.get(reply_to_ref)

    case result do
      {:done, value, _env} ->
        send(final_reply_to, {tag, :result, value})

      {:stopped, reason, _env} ->
        send(final_reply_to, {tag, :stopped, reason})

      {:thrown, error, _env} ->
        send(final_reply_to, {tag, :throw, error})
    end
  end
end
