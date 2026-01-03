defmodule Skuld.Effects.TaggedWriter do
  @moduledoc """
  Tagged Writer effect - accumulate multiple independent logs during computation.

  Like `Writer`, but allows multiple independent writer logs identified by tags.

  ## Example

      alias Skuld.Comp
      alias Skuld.Effects.TaggedWriter

      comp do
        _ <- TaggedWriter.tell(:audit, "user logged in")
        _ <- TaggedWriter.tell(:metrics, {:counter, :login, 1})
        _ <- TaggedWriter.tell(:audit, "user viewed dashboard")
        return(:ok)
      end
      |> TaggedWriter.with_handler(:audit)
      |> TaggedWriter.with_handler(:metrics)
      |> Comp.run()

      # Result includes both logs accessible via get_log/2
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Tell, [:tag, :msg])
  def_op(Peek, [:tag])
  def_op(SetLog, [:tag, :log])

  #############################################################################
  ## Effect Operations
  #############################################################################

  @doc "Append a message to the log for the given tag"
  @spec tell(atom(), term()) :: Types.computation()
  def tell(tag, msg) do
    Comp.effect(@sig, %Tell{tag: tag, msg: msg})
  end

  @doc "Read the current log for the given tag (reverse chronological order)"
  @spec peek(atom()) :: Types.computation()
  def peek(tag) do
    Comp.effect(@sig, %Peek{tag: tag})
  end

  @doc """
  Run a computation and capture its log output for the given tag.

  Returns `{result, captured_log}` where captured_log contains only
  the messages written to this tag during the inner computation.
  """
  @spec listen(atom(), Types.computation()) :: Types.computation()
  def listen(tag, comp) do
    Comp.bind(peek(tag), fn initial_log ->
      Comp.bind(comp, fn result ->
        Comp.bind(peek(tag), fn final_log ->
          # Calculate what was added (new logs are at the front)
          captured = Enum.take(final_log, length(final_log) - length(initial_log))
          Comp.pure({result, captured})
        end)
      end)
    end)
  end

  @doc """
  Run a computation that returns `{value, log_transform_fn}`.

  The transform function is applied to the logs written to the given tag
  during the computation.
  """
  @spec pass(atom(), Types.computation()) :: Types.computation()
  def pass(tag, comp) do
    Comp.bind(peek(tag), fn initial_log ->
      Comp.bind(comp, fn {value, transform_fn} ->
        Comp.bind(peek(tag), fn final_log ->
          # Calculate captured logs
          captured = Enum.take(final_log, length(final_log) - length(initial_log))
          # Apply transform
          transformed = transform_fn.(captured)
          # Replace captured logs with transformed version
          new_log = transformed ++ initial_log

          Comp.bind(set_log(tag, new_log), fn _ ->
            Comp.pure(value)
          end)
        end)
      end)
    end)
  end

  @doc "Censor: transform all logs written to the given tag during a computation"
  @spec censor(atom(), Types.computation(), (list() -> list())) :: Types.computation()
  def censor(tag, comp, transform_fn) do
    pass(
      tag,
      Comp.bind(comp, fn result ->
        Comp.pure({result, transform_fn})
      end)
    )
  end

  # Internal: set the log directly (used by pass)
  defp set_log(tag, new_log) do
    Comp.effect(@sig, %SetLog{tag: tag, log: new_log})
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped TaggedWriter handler for a computation with the given tag.

  Multiple TaggedWriter handlers with different tags can be installed simultaneously.

  ## Example

      comp do
        _ <- TaggedWriter.tell(:foo, "message 1")
        _ <- TaggedWriter.tell(:bar, "message 2")
        return(:done)
      end
      |> TaggedWriter.with_handler(:foo)
      |> TaggedWriter.with_handler(:bar)
      |> Comp.run()
  """
  @spec with_handler(Types.computation(), atom(), list()) :: Types.computation()
  def with_handler(comp, tag, initial \\ []) do
    state_key = state_key(tag)

    comp
    |> Comp.scoped(fn env ->
      previous_log = Env.get_state(env, state_key)
      modified = Env.put_state(env, state_key, initial)

      finally_k = fn value, e ->
        restored_env =
          case previous_log do
            nil -> %{e | state: Map.delete(e.state, state_key)}
            log -> Env.put_state(e, state_key, log)
          end

        {value, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  @doc "Get the accumulated log for the given tag from the environment"
  @spec get_log(Types.env(), atom()) :: [term()]
  def get_log(env, tag) do
    Env.get_state(env, state_key(tag), [])
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(%Tell{tag: tag, msg: msg}, env, k) do
    state_key = state_key(tag)
    current = Env.get_state(env, state_key, [])
    updated = [msg | current]
    new_env = Env.put_state(env, state_key, updated)
    # Return the updated log as the result
    k.(updated, new_env)
  end

  @impl Skuld.Comp.IHandler
  def handle(%Peek{tag: tag}, env, k) do
    current = Env.get_state(env, state_key(tag), [])
    k.(current, env)
  end

  @impl Skuld.Comp.IHandler
  def handle(%SetLog{tag: tag, log: new_log}, env, k) do
    new_env = Env.put_state(env, state_key(tag), new_log)
    k.(:ok, new_env)
  end

  #############################################################################
  ## Utilities
  #############################################################################

  @doc "Tell multiple messages to the given tag"
  @spec tell_many(atom(), [term()]) :: Types.computation()
  def tell_many(tag, messages) do
    Comp.traverse(messages, &tell(tag, &1))
  end

  @doc "Clear the log for the given tag"
  @spec clear(atom()) :: Types.computation()
  def clear(tag) do
    set_log(tag, [])
  end

  #############################################################################
  ## Private
  #############################################################################

  defp state_key(tag), do: {__MODULE__, tag}
end
