defmodule Skuld.SerializableCoroutine do
  @moduledoc """
  Helpers for building coroutines with serializable effect logs.

  `new/2` constructs a Coroutine with `EffectLogger` installed innermost,
  so every effect invocation across all handlers is captured in a
  JSON-serializable log. The returned value is a plain `%Coroutine.Pending{}`
  — run it, suspend it, resume it just like any other coroutine.

  When the coroutine suspends, the log is accessible via `get_log/1`
  (from the env in `%Coroutine.ExternalSuspended{}`). `serialize/1` and
  `deserialize/1` convert the log to/from JSON.

  For resume: deserialize the log, build a new computation with
  `EffectLogger.with_resume/4`, install handlers, and wrap in a new
  Coroutine.

  ## Usage

      coroutine =
        SerializableCoroutine.new(my_comp, fn comp ->
          comp
          |> State.with_handler(0)
          |> Throw.with_handler()
          |> Yield.with_handler()
        end)

      case Coroutine.run(coroutine) do
        %Coroutine.ExternalSuspended{value: yielded} = suspended ->
          json = SerializableCoroutine.serialize(SerializableCoroutine.get_log(suspended))
          # persist json...

          {:ok, log} = SerializableCoroutine.deserialize(json)
          SerializableCoroutine.run(log, my_comp, handlers_fun, user_input)

        %Coroutine.Completed{result: result} ->
          result
      end

  ## EffectLogger placement

  `EffectLogger.with_logging()` is installed **innermost** (right after
  the computation, before `handlers_fun`), so its scope runs last and
  wraps all subsequently installed handlers. This ensures every effect
  invocation is captured.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Coroutine
  alias Skuld.Effects.EffectLogger
  alias Skuld.Effects.EffectLogger.Log

  @doc """
  Build a Coroutine with EffectLogger installed innermost.

  `handlers_fun` receives the computation after EffectLogger is installed.
  Install application-level handlers here (State, Throw, Yield, etc.).

  Returns a plain `%Coroutine.Pending{}`.

  ## Example

      SerializableCoroutine.new(my_comp, fn comp ->
        comp
        |> State.with_handler(0)
        |> Throw.with_handler()
      end)
  """
  @spec new(Types.computation(), (Types.computation() -> Types.computation())) ::
          Coroutine.Pending.t()
  def new(comp, handlers_fun)
      when is_function(comp, 2) and is_function(handlers_fun, 1) do
    wrapped =
      comp
      |> EffectLogger.with_logging()
      |> handlers_fun.()

    Coroutine.new(wrapped, Env.new())
  end

  @doc """
  Run a serialisable coroutine.

  Clauses dispatch on the input type:

  - `%Coroutine.ExternalSuspended{}` — resume with a value (delegates to `Coroutine.run`)
  - `%Coroutine.Pending{}` — start a fresh coroutine (delegates to `Coroutine.run`)
  - `%Log{}` — cold resume from a deserialised log
  - `binary` (JSON string) — deserialise to a log, then cold resume

  For cold resume, the original computation and handler stack must be
  provided — these aren't stored in the log.

  ## Examples

      # Resume a live suspended coroutine
      SerializableCoroutine.run(suspended, "Alice")

      # Cold resume from a deserialised log
      SerializableCoroutine.run(log, wizard, handlers_fun, "Alice")

      # Cold resume from a serialised JSON string
      SerializableCoroutine.run(json, wizard, handlers_fun, "Alice")
  """
  @spec run(Coroutine.t(), term()) :: Coroutine.t()
  def run(%Coroutine.ExternalSuspended{} = fiber, value) do
    Coroutine.run(fiber, value)
  end

  def run(%Coroutine.Pending{} = fiber) do
    Coroutine.run(fiber)
  end

  @spec run(Log.t(), Types.computation(), (Types.computation() -> Types.computation()), term()) ::
          Coroutine.t()
  def run(%Log{} = log, comp, handlers_fun, value) do
    comp
    |> EffectLogger.with_resume(log, value)
    |> handlers_fun.()
    |> then(&Coroutine.new(&1, Env.new()))
    |> Coroutine.run()
  end

  @spec run(String.t(), Types.computation(), (Types.computation() -> Types.computation()), term()) ::
          Coroutine.t()
  def run(json, comp, handlers_fun, value) when is_binary(json) do
    {:ok, log} = deserialize(json)
    run(log, comp, handlers_fun, value)
  end

  @doc """
  Extract the EffectLogger log from a suspended coroutine.

  The log is stored in the environment at suspension time.
  Returns `nil` if no log is found.
  """
  @spec get_log(Coroutine.ExternalSuspended.t()) :: Log.t() | nil
  def get_log(%Coroutine.ExternalSuspended{env: env}) do
    EffectLogger.get_log(env)
  end

  @doc """
  Serialize a log to JSON.

  Returns a JSON string suitable for storage.
  """
  @spec serialize(Log.t()) :: String.t()
  def serialize(log) do
    log
    |> Log.finalize()
    |> Jason.encode!()
  end

  @doc """
  Deserialize a log from JSON.

  Returns `{:ok, log}` on success.
  """
  @spec deserialize(String.t()) :: {:ok, Log.t()} | {:error, Jason.DecodeError.t()}
  def deserialize(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> {:ok, Log.from_json(data)}
      {:error, _} = error -> error
    end
  end
end
