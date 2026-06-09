defmodule Skuld.SerializableCoroutine do
  @moduledoc """
  Helpers for building coroutines with serializable effect logs.

  Part of the `skuld_durable` package, which provides durable execution
  through SerializableCoroutine (pause-serialize-resume workflows) and
  EffectLogger (execution logging and replay). See the
  [architecture guide](https://hexdocs.pm/skuld/architecture.html)
  for how these fit into the Skuld ecosystem.

  `new/2` constructs a struct with `EffectLogger` installed innermost,
  so every effect invocation across all handlers is captured in a
  JSON-serializable log.

  When the coroutine suspends, the log is accessible via `get_log/1`
  (from the env in `%Coroutine.ExternalSuspended{}`). `serialize/1` and
  `deserialize/1` convert the log to/from JSON.

  `run` handles all states — fresh start, live resume, and cold resume
  from serialised state.

  ## Usage

      sc = SerializableCoroutine.new(wizard, fn comp ->
        comp |> State.with_handler(0) |> Yield.with_handler() |> Throw.with_handler()
      end)

      # Run fresh — suspends at first yield
      suspended = SerializableCoroutine.run(sc)

      # Serialize and persist
      json = SerializableCoroutine.serialize(SerializableCoroutine.get_log(suspended))

      # Later: cold resume from serialised state
      SerializableCoroutine.run(json, sc, "Alice")

      # Or resume a live suspended coroutine directly
      SerializableCoroutine.run(suspended, "Alice")
  """

  alias Skuld.Comp.Env
  alias Skuld.Comp.Types
  alias Skuld.Coroutine
  alias Skuld.Effects.EffectLogger
  alias Skuld.Effects.EffectLogger.Log

  defstruct [:comp, :handlers_fun]

  @typedoc """
  A serialisable coroutine capturing the computation and handler stack.
  """
  @type t :: %__MODULE__{
          comp: Types.computation(),
          handlers_fun: (Types.computation() -> Types.computation())
        }

  @doc """
  Build a serialisable coroutine.

  `handlers_fun` receives the computation after EffectLogger is installed.
  Install application-level handlers here (State, Throw, Yield, etc.).

  ## Example

      SerializableCoroutine.new(my_comp, fn comp ->
        comp |> State.with_handler(0) |> Throw.with_handler()
      end)
  """
  @spec new(Types.computation(), (Types.computation() -> Types.computation())) :: t()
  def new(comp, handlers_fun)
      when is_function(comp, 2) and is_function(handlers_fun, 1) do
    %__MODULE__{comp: comp, handlers_fun: handlers_fun}
  end

  @doc """
  Run a serialisable coroutine.

  Clauses dispatch on the input type:

  - `t()` — start fresh, returns a Coroutine sum-type
  - `t()`, `value` — resume a live suspended fiber (delegates to `Coroutine.run`)
  - `%Log{}`, `t()`, `value` — cold resume from a deserialised log
  - `binary`, `t()`, `value` — deserialise JSON to a log, then cold resume
  - `Coroutine.t()`, `value` — resume a live Coroutine fiber directly

  ## Examples

      sc = SerializableCoroutine.new(wizard, handlers)

      # Start fresh
      suspended = SerializableCoroutine.run(sc)

      # Resume a live suspended fiber
      SerializableCoroutine.run(suspended, "Alice")

      # Cold resume from a deserialised log
      SerializableCoroutine.run(log, sc, "Alice")

      # Cold resume from serialised JSON
      SerializableCoroutine.run(json, sc, "Alice")
  """
  @spec run(t()) :: Coroutine.t()
  def run(%__MODULE__{comp: comp, handlers_fun: handlers_fun}) do
    comp
    |> EffectLogger.with_logging()
    |> handlers_fun.()
    |> then(&Coroutine.new(&1, Env.new()))
    |> Coroutine.run()
  end

  def run(%Coroutine.ExternalSuspended{} = fiber, value) do
    Coroutine.run(fiber, value)
  end

  @spec run(Log.t(), t(), term()) :: Coroutine.t()
  def run(%Log{} = log, %__MODULE__{comp: comp, handlers_fun: handlers_fun}, value) do
    comp
    |> EffectLogger.with_resume(log, value)
    |> handlers_fun.()
    |> then(&Coroutine.new(&1, Env.new()))
    |> Coroutine.run()
  end

  @spec run(String.t(), t(), term()) :: Coroutine.t()
  def run(json, %__MODULE__{} = sc, value) when is_binary(json) do
    {:ok, log} = deserialize(json)
    run(log, sc, value)
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
