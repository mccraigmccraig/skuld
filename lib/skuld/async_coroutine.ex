defmodule Skuld.AsyncCoroutine do
  @moduledoc """
  Run a computation in a separate process, bridging yields, throws, and results
  back to the calling process via messages.

  This is for running effectful computations from non-effectful code (e.g., LiveView).
  If you're inside a computation and want concurrency, use `Skuld.Effects.FiberPool` instead.

  ## Messages

  The runner sends messages to the caller in the form `{AsyncCoroutine, tag, result}`:

  - `%ExternalSuspend{value: v, data: d, resume: nil}` - computation yielded, waiting for resume
  - `%Throw{error: e}` - computation threw an error
  - `%Cancelled{reason: r}` - computation was cancelled
  - Any other value - computation completed successfully

  The `ExternalSuspend.data` field contains any decorations added by scoped effects
  (e.g., EffectLogger attaches its log here). The `resume` field is always `nil`
  in IPC messages since resume functions can't be sent between processes.

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
      {:ok, runner} = AsyncCoroutine.run(computation, tag: :create_todo)

      # Or start sync for fast-yielding computations
      {:ok, runner, %ExternalSuspend{value: :ready}} =
        AsyncCoroutine.run_sync(computation, tag: :create_todo)

      # In handle_info - single clause handles all messages for a tag:
      def handle_info({AsyncCoroutine, :create_todo, result}, socket) do
        case result do
          %ExternalSuspend{value: value, data: data} ->
            handle_yield(value, data, socket)

          %Throw{error: error} ->
            handle_error(error, socket)

          %Cancelled{reason: reason} ->
            handle_cancelled(reason, socket)

          value ->
            handle_success(value, socket)
        end
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

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :create_user)

      # Handle yields
      def handle_info({AsyncCoroutine, :create_user, %ExternalSuspend{value: :get_name}}, socket) do
        # Maybe wait for user input, then:
        AsyncCoroutine.run(runner, "Alice")
        {:noreply, socket}
      end

      def handle_info({AsyncCoroutine, :create_user, %ExternalSuspend{value: :get_email}}, socket) do
        AsyncCoroutine.run(runner, "alice@example.com")
        {:noreply, socket}
      end

      def handle_info({AsyncCoroutine, :create_user, {:ok, user}}, socket) do
        {:noreply, assign(socket, user: user)}
      end
  """

  alias Skuld.Comp.Cancelled
  alias Skuld.Comp.Env
  alias Skuld.Comp.ExternalSuspend
  alias Skuld.Comp.Throw, as: ThrowStruct
  alias Skuld.Coroutine
  alias Skuld.Coroutine.Error
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
  Run a computation in a separate process.

  The computation will have `Throw.with_handler/1` and `Yield.with_handler/1`
  added automatically (outermost). Add your other handlers before calling run.

  ## Options

  - `:tag` - Required. Tag for messages, e.g. `:create_todo`
  - `:caller` - Process to send messages to (default: `self()`)
  - `:link` - Whether to link the runner process (default: `true`)

  ## Returns

  `{:ok, runner}` where runner is used with `run/2` and `cancel/1`.
  """
  @spec run(Skuld.Comp.Types.computation(), keyword()) :: {:ok, t()}
  def run(computation, opts) when is_function(computation, 2) do
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
  Run a computation and wait synchronously for the first response.

  Use this when you know the computation will quickly yield after setup
  (e.g., a command processor that immediately yields waiting for commands).
  Avoids dealing with async messages for the initial handshake.

  ## Options

  Same as `run/2`, plus:

  - `:timeout` - Maximum time to wait in ms (default: 5000)

  ## Returns

  - `{:ok, runner, result}` where result is one of:
    - `%ExternalSuspend{value: v, data: d}` - computation yielded
    - `%Throw{error: e}` - computation threw
    - `%Cancelled{reason: r}` - computation cancelled
    - Any other value - computation completed
  - `{:error, :timeout}` - timed out waiting for first response

  ## Example

      # Command processor that yields immediately for commands
      {:ok, runner, %ExternalSuspend{value: :ready}} =
        command_processor
        |> Reader.with_handler(context)
        |> AsyncCoroutine.run_sync(tag: :processor)

      # Now resume synchronously for quick commands
      %ExternalSuspend{value: :ready} = AsyncCoroutine.run_sync(runner, %QuickCommand{})
  """
  @spec run_sync(Skuld.Comp.Types.computation(), keyword()) ::
          {:ok, t(), term()}
          | {:error, :timeout}
  def run_sync(computation, opts) when is_function(computation, 2) do
    timeout = Keyword.get(opts, :timeout, 5000)
    tag = Keyword.fetch!(opts, :tag)

    {:ok, runner} = run(computation, opts)

    receive do
      {__MODULE__, ^tag, result} -> {:ok, runner, result}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Resume a yielded computation with a value (async).

  Call this after receiving a `{AsyncCoroutine, tag, %ExternalSuspend{}}` message.
  The next response will arrive via message to the caller (or `:reply_to` if specified).

  ## Options

  - `:reply_to` - Process to send the response to (default: original caller from run)
  """
  @spec run(t(), term(), keyword()) :: :ok
  def run(%__MODULE__{ref: ref, pid: pid}, value, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to)
    send(pid, {:async_resume, ref, value, reply_to})
    :ok
  end

  @doc """
  Resume a yielded computation and wait synchronously for the next response.

  Blocks until the computation yields again, completes, throws, or times out.

  This can be called from any process - the response will be sent to the calling
  process, not necessarily the original caller from `run/2`.

  ## Options

  - `:timeout` - Maximum time to wait in ms (default: 5000)

  ## Returns

  - `%ExternalSuspend{value: v, data: d}` - computation yielded again
  - `%Throw{error: e}` - computation threw
  - `%Cancelled{reason: r}` - computation cancelled
  - Any other value - computation completed
  - `{:error, :timeout}` - timed out waiting for response

  ## Example

      {:ok, runner} = AsyncCoroutine.run(computation, tag: :cmd)

      # First yield arrives via message
      receive do
        {AsyncCoroutine, :cmd, %ExternalSuspend{value: :ready}} -> :ok
      end

      # Now resume and wait synchronously
      case AsyncCoroutine.run_sync(runner, %SomeCommand{}) do
        %ExternalSuspend{value: :ready} -> # ready for next command
        %Throw{error: e} -> # something went wrong
        %Cancelled{reason: r} -> # was cancelled
        value -> # computation finished with value
      end
  """
  @spec run_sync(t(), term(), keyword()) ::
          ExternalSuspend.t()
          | ThrowStruct.t()
          | Cancelled.t()
          | term()
          | {:error, :timeout}
  def run_sync(%__MODULE__{ref: ref, pid: pid, tag: tag}, value, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    send(pid, {:async_resume, ref, value, self()})

    receive do
      {__MODULE__, ^tag, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Cancel a running computation (async).

  Sends a cancel signal to the computation. The computation will invoke `leave_scope`
  for all active scoped effects (allowing cleanup), then send a
  `{AsyncCoroutine, tag, %Cancelled{reason: :cancelled}}` message to the caller.

  Use `cancel_sync/2` if you need to wait for the cancellation to complete.
  """
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{ref: ref, pid: pid, monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    send(pid, {:async_cancel, ref})
    :ok
  end

  @doc """
  Cancel a running computation and wait for it to complete.

  Like `cancel/1`, but blocks until the computation has finished its cleanup
  (invoking `leave_scope` for all active scoped effects) and returns the result.

  This can be called from any process - the response will be sent to the calling
  process, not necessarily the original caller from `start/2`.

  ## Options

  - `:timeout` - Maximum time to wait in ms (default: 5000)

  ## Returns

  - `%Cancelled{reason: :cancelled}` - computation was cancelled successfully
  - `{:error, :timeout}` - timed out waiting for cancellation to complete

  ## Example

      {:ok, runner, %ExternalSuspend{value: :ready}} =
        AsyncCoroutine.run_sync(computation, tag: :worker)

      # Cancel and wait for cleanup to finish
      %Cancelled{reason: :cancelled} = AsyncCoroutine.cancel_sync(runner)
  """
  @spec cancel_sync(t(), keyword()) :: Cancelled.t() | {:error, :timeout}
  def cancel_sync(%__MODULE__{ref: ref, pid: pid, monitor_ref: monitor_ref, tag: tag}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)

    Process.demonitor(monitor_ref, [:flush])
    # Send cancel with self() as the implicit recipient (via process dictionary override)
    # But actually we need to tell the runner to reply to us, not the original caller
    send(pid, {:async_cancel_sync, ref, self()})

    receive do
      {__MODULE__, ^tag, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  # Child process entry point
  defp run_bridged(computation, caller, tag, ref) do
    comp =
      computation
      |> Throw.with_handler()
      |> Yield.with_handler()

    case Coroutine.new(comp, Env.new()) |> Coroutine.run() do
      %Coroutine.ExternalSuspended{} = fiber ->
        run_yield_loop(fiber, caller, tag, ref, caller)

      other ->
        send(caller, {__MODULE__, tag, coroutine_to_ipc(other)})
    end
  end

  # Main yield/resume loop
  # - reply_to: where to send THIS yield's suspend message
  # - original_caller: default destination (reset target after override)
  defp run_yield_loop(
         %Coroutine.ExternalSuspended{value: value, data: data} = fiber,
         original_caller,
         tag,
         ref,
         reply_to
       ) do
    ipc_suspend = %ExternalSuspend{value: value, data: data, resume: nil}
    send(reply_to, {__MODULE__, tag, ipc_suspend})

    receive do
      {:async_resume, ^ref, value, nil} ->
        case Coroutine.run(fiber, value) do
          %Coroutine.ExternalSuspended{} = new_fiber ->
            run_yield_loop(new_fiber, original_caller, tag, ref, original_caller)

          other ->
            send(original_caller, {__MODULE__, tag, coroutine_to_ipc(other)})
        end

      {:async_resume, ^ref, value, override} when not is_nil(override) ->
        case Coroutine.run(fiber, value) do
          %Coroutine.ExternalSuspended{} = new_fiber ->
            run_yield_loop(new_fiber, original_caller, tag, ref, override)

          other ->
            send(override, {__MODULE__, tag, coroutine_to_ipc(other)})
        end

      {:async_cancel, ^ref} ->
        cancelled = Coroutine.cancel(fiber, :cancelled) |> coroutine_to_ipc()
        send(reply_to, {__MODULE__, tag, cancelled})

      {:async_cancel_sync, ^ref, sync_reply_to} ->
        cancelled = Coroutine.cancel(fiber, :cancelled) |> coroutine_to_ipc()
        send(sync_reply_to, {__MODULE__, tag, cancelled})
    end
  end

  #############################################################################
  ## IPC Conversion (Coroutine states → Comp sentinels)
  #############################################################################

  defp coroutine_to_ipc(%Coroutine.Completed{result: result}), do: result
  defp coroutine_to_ipc(%Coroutine.Errored{error: error}), do: error_to_throw(error)
  defp coroutine_to_ipc(%Coroutine.Cancelled{reason: reason}), do: %Cancelled{reason: reason}

  defp error_to_throw(%Error{type: :cancelled, error: reason}) do
    %Cancelled{reason: reason}
  end

  defp error_to_throw(%Error{type: :exception, error: exception, stacktrace: stacktrace}) do
    %ThrowStruct{error: %{kind: :error, payload: exception, stacktrace: stacktrace}}
  end

  defp error_to_throw(%Error{type: :throw, error: value, stacktrace: nil}) do
    %ThrowStruct{error: value}
  end

  defp error_to_throw(%Error{type: :throw, error: value, stacktrace: stacktrace}) do
    %ThrowStruct{error: %{kind: :throw, payload: value, stacktrace: stacktrace}}
  end

  defp error_to_throw(%Error{type: :exit, error: reason, stacktrace: stacktrace}) do
    %ThrowStruct{error: %{kind: :exit, payload: reason, stacktrace: stacktrace}}
  end
end
