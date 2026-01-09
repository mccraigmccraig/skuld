defmodule Skuld.Comp.ConvertThrow do
  @moduledoc """
  Utilities for converting Elixir exceptions to Throw effects.

  Provides a macro and helper function for wrapping code in try/catch
  that converts exceptions (raise/throw/exit) to Skuld Throw effects.
  """

  @doc """
  Wrap an expression in a computation that catches exceptions and converts
  them to Throw effects.

  This is used by the `comp` macro to wrap the first expression, ensuring
  that exceptions raised during evaluation are properly converted.

  ## Example

      # Instead of:
      Skuld.Comp.bind(Risky.boom!(), fn x -> x + 1 end)
      # Which raises before bind is called

      # Generate:
      Skuld.Comp.bind(
        Skuld.Comp.ConvertThrow.wrap(Risky.boom!()),
        fn x -> x + 1 end
      )
      # Which catches the exception and converts to Throw
  """
  defmacro wrap(expr) do
    quote do
      fn env, k ->
        try do
          result = unquote(expr)
          Skuld.Comp.call(result, env, k)
        catch
          kind, payload ->
            Skuld.Comp.ConvertThrow.handle_exception(
              kind,
              payload,
              __STACKTRACE__,
              env
            )
        end
      end
    end
  end

  @doc """
  Convert an exception to a Throw result.

  Re-raises `InvalidComputation` errors (programming bugs that should fail fast).
  Other exceptions are wrapped in a Throw struct and passed through leave_scope.
  """
  @spec handle_exception(atom(), term(), list(), map()) :: {term(), map()}
  def handle_exception(:error, %Skuld.Comp.InvalidComputation{} = e, stacktrace, _env) do
    reraise e, stacktrace
  end

  def handle_exception(kind, payload, stacktrace, env) do
    error = %{kind: kind, payload: payload, stacktrace: stacktrace}
    leave_scope = Map.get(env, :leave_scope, fn r, e -> {r, e} end)
    leave_scope.(%Skuld.Comp.Throw{error: error}, env)
  end
end
