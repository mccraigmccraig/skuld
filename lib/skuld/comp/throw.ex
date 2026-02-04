defmodule Skuld.Comp.Throw do
  @moduledoc "Error result that Catch recognizes"

  @type t :: %__MODULE__{error: term()}

  defstruct [:error]

  defimpl Skuld.Comp.ISentinel do
    # Throw goes through leave_scope so Catch can intercept it
    def run(result, env), do: env.leave_scope.(result, env)

    # Elixir exception (raise) - reraise with original stacktrace
    def run!(%Skuld.Comp.Throw{
          error: %{kind: :error, payload: exception, stacktrace: stacktrace}
        }) do
      reraise exception, stacktrace
    end

    # Elixir throw - wrap in exception and reraise
    def run!(%Skuld.Comp.Throw{
          error: %{kind: :throw, payload: value, stacktrace: stacktrace}
        }) do
      reraise Skuld.Comp.UncaughtThrow.exception(value: value), stacktrace
    end

    # Elixir exit - wrap in exception and reraise
    def run!(%Skuld.Comp.Throw{
          error: %{kind: :exit, payload: reason, stacktrace: stacktrace}
        }) do
      reraise Skuld.Comp.UncaughtExit.exception(reason: reason), stacktrace
    end

    # Skuld Throw.throw (user error without stacktrace) - raise with error info
    def run!(%Skuld.Comp.Throw{error: error}) do
      raise Skuld.Comp.ThrowError, error: error
    end

    def sentinel?(_), do: true
    def suspend?(_), do: false
    def error?(_), do: true

    def serializable_payload(%Skuld.Comp.Throw{error: error}) do
      %{error: error}
    end
  end
end
