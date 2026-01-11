defmodule Skuld.Effects.Writer do
  @moduledoc """
  Writer effect - accumulate a log during computation.

  Supports both simple single-log usage and multiple independent logs via tags.

  ## Simple Usage (default tag)

      use Skuld.Syntax
      alias Skuld.Effects.Writer

      comp do
        _ <- Writer.tell("step 1")
        _ <- Writer.tell("step 2")
        :done
      end
      |> Writer.with_handler([], output: fn result, log -> {result, log} end)
      |> Comp.run!()
      #=> {:done, ["step 2", "step 1"]}

  ## Multiple Logs (explicit tags)

      comp do
        _ <- Writer.tell(:audit, "user logged in")
        _ <- Writer.tell(:metrics, {:counter, :login, 1})
        _ <- Writer.tell(:audit, "user viewed dashboard")
        :ok
      end
      |> Writer.with_handler([], tag: :audit, output: fn r, log -> {r, log} end)
      |> Writer.with_handler([], tag: :metrics)
      |> Comp.run!()
      #=> {:ok, ["user viewed dashboard", "user logged in"]}

  ## Scoped Operations and Throw

  The scoped operations (`listen`, `pass`, `censor`) use a peek-before/peek-after
  pattern to calculate captured logs. This means on abnormal exit (throw):

  - Logs written before the throw **persist** in state (not rolled back)
  - `listen` does not capture partial logs - the throw propagates out
  - `censor` does not apply its transform - logs leak out untransformed

  This "fire-and-forget" semantic is intentional for logging (you typically want
  to see logs leading up to an error).
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

  def_op(Tell, [:tag, :msg], atom_fields: [:tag])
  def_op(Peek, [:tag], atom_fields: [:tag])
  def_op(SetLog, [:tag, :log], atom_fields: [:tag])

  #############################################################################
  ## Effect Operations
  #############################################################################

  @doc """
  Append a message to the log.

  ## Examples

      Writer.tell("message")           # use default tag
      Writer.tell(:audit, "message")   # use explicit tag
  """
  @spec tell(atom(), term()) :: Types.computation()
  def tell(tag_or_msg, msg \\ nil)

  def tell(tag, msg) when is_atom(tag) and msg != nil do
    Comp.effect(@sig, %Tell{tag: tag, msg: msg})
  end

  def tell(msg, nil) do
    Comp.effect(@sig, %Tell{tag: @sig, msg: msg})
  end

  @doc """
  Read the current log (reverse chronological order).

  ## Examples

      Writer.peek()        # use default tag
      Writer.peek(:audit)  # use explicit tag
  """
  @spec peek(atom()) :: Types.computation()
  def peek(tag \\ @sig) do
    Comp.effect(@sig, %Peek{tag: tag})
  end

  @doc """
  Run a computation and capture its log output.

  Returns `{result, captured_log}` where captured_log contains only
  the messages written during the inner computation.

  ## Examples

      Writer.listen(comp)          # use default tag
      Writer.listen(:audit, comp)  # use explicit tag
  """
  @spec listen(Types.computation()) :: Types.computation()
  def listen(comp) do
    listen(@sig, comp)
  end

  @spec listen(atom(), Types.computation()) :: Types.computation()
  def listen(tag, comp) when is_atom(tag) do
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

  The transform function is applied to the logs written during the computation.

  ## Examples

      Writer.pass(comp)          # use default tag
      Writer.pass(:audit, comp)  # use explicit tag
  """
  @spec pass(Types.computation()) :: Types.computation()
  def pass(comp) do
    pass(@sig, comp)
  end

  @spec pass(atom(), Types.computation()) :: Types.computation()
  def pass(tag, comp) when is_atom(tag) do
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

  @doc """
  Censor: transform all logs written during a computation.

  ## Examples

      Writer.censor(comp, &Enum.map(&1, fn m -> "[REDACTED]" end))
      Writer.censor(:audit, comp, &Enum.reverse/1)
  """
  @spec censor(Types.computation(), (list() -> list())) :: Types.computation()
  def censor(comp, transform_fn) when is_function(transform_fn, 1) do
    censor(@sig, comp, transform_fn)
  end

  @spec censor(atom(), Types.computation(), (list() -> list())) :: Types.computation()
  def censor(tag, comp, transform_fn) when is_atom(tag) and is_function(transform_fn, 1) do
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
  Install a scoped Writer handler for a computation.

  ## Options

  - `tag` - the log tag (default: `Skuld.Effects.Writer`)
  - `output` - optional function `(result, final_log) -> new_result`
    to transform the result before returning.

  ## Examples

      # Simple usage with default tag
      comp do
        _ <- Writer.tell("step 1")
        _ <- Writer.tell("step 2")
        :done
      end
      |> Writer.with_handler()
      |> Comp.run!()
      #=> :done

      # Include final log in result
      comp do
        _ <- Writer.tell("step 1")
        :done
      end
      |> Writer.with_handler([], output: fn result, log -> {result, log} end)
      |> Comp.run!()
      #=> {:done, ["step 1"]}

      # With explicit tag
      comp do
        _ <- Writer.tell(:audit, "action 1")
        :done
      end
      |> Writer.with_handler([], tag: :audit, output: fn r, log -> {r, log} end)
      |> Comp.run!()
      #=> {:done, ["action 1"]}

      # Multiple logs
      comp do
        _ <- Writer.tell(:foo, "message 1")
        _ <- Writer.tell(:bar, "message 2")
        :done
      end
      |> Writer.with_handler([], tag: :foo)
      |> Writer.with_handler([], tag: :bar)
      |> Comp.run!()
      #=> :done
  """
  @spec with_handler(Types.computation(), list(), keyword()) :: Types.computation()
  def with_handler(comp, initial \\ [], opts \\ []) do
    tag = Keyword.get(opts, :tag, @sig)
    output = Keyword.get(opts, :output)
    state_key = state_key(tag)

    comp
    |> Comp.scoped(fn env ->
      previous_log = Env.get_state(env, state_key)
      modified = Env.put_state(env, state_key, initial)

      finally_k = fn value, e ->
        final_log = Env.get_state(e, state_key, [])

        restored_env =
          case previous_log do
            nil -> %{e | state: Map.delete(e.state, state_key)}
            log -> Env.put_state(e, state_key, log)
          end

        transformed_value =
          if output do
            output.(value, final_log)
          else
            value
          end

        {transformed_value, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  @doc """
  Get the accumulated log from the environment.

  ## Examples

      Writer.get_log(env)          # use default tag
      Writer.get_log(env, :audit)  # use explicit tag
  """
  @spec get_log(Types.env(), atom()) :: [term()]
  def get_log(env, tag \\ @sig) do
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

  @doc """
  Tell multiple messages.

  ## Examples

      Writer.tell_many(["a", "b", "c"])           # use default tag
      Writer.tell_many(:audit, ["a", "b", "c"])   # use explicit tag
  """
  @spec tell_many([term()]) :: Types.computation()
  def tell_many(messages) when is_list(messages) do
    tell_many(@sig, messages)
  end

  @spec tell_many(atom(), [term()]) :: Types.computation()
  def tell_many(tag, messages) when is_atom(tag) and is_list(messages) do
    Comp.traverse(messages, &tell(tag, &1))
  end

  @doc """
  Clear the log.

  ## Examples

      Writer.clear()        # use default tag
      Writer.clear(:audit)  # use explicit tag
  """
  @spec clear(atom()) :: Types.computation()
  def clear(tag \\ @sig) do
    set_log(tag, [])
  end

  #############################################################################
  ## State Key Helper
  #############################################################################

  @doc """
  Returns the env.state key used for a given tag.

  Useful for configuring EffectLogger's `state_keys` filter.

  ## Examples

      # Only capture Writer log in EffectLogger snapshots
      EffectLogger.with_logging(state_keys: [Writer.state_key(:audit)])

      # Multiple logs
      EffectLogger.with_logging(state_keys: [
        Writer.state_key(:audit),
        Writer.state_key(:metrics)
      ])
  """
  @spec state_key(atom()) :: {module(), atom()}
  def state_key(tag), do: {__MODULE__, tag}
end
