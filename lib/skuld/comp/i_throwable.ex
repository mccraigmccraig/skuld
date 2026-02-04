defprotocol Skuld.Comp.IThrowable do
  @moduledoc """
  Protocol for unwrapping exceptions in `Throw.try_catch/1`.

  When an exception is caught inside a computation and processed by
  `Throw.try_catch/1`, this protocol determines how the exception is
  converted to an error value.

  ## Default Behavior

  By default (via the `Any` fallback), exceptions are returned as-is:

      raise ArgumentError, "bad input"
      # try_catch returns: {:error, %ArgumentError{message: "bad input"}}

  ## Custom Unwrapping

  Domain exceptions can implement this protocol to provide cleaner error values
  suitable for pattern matching:

      defmodule MyApp.NotFoundError do
        defexception [:entity, :id]

        @impl true
        def message(%{entity: entity, id: id}) do
          "\#{entity} not found: \#{id}"
        end
      end

      defimpl Skuld.Comp.IThrowable, for: MyApp.NotFoundError do
        def unwrap(%{entity: entity, id: id}), do: {:not_found, entity, id}
      end

  Now when code raises this exception:

      raise MyApp.NotFoundError, entity: :user, id: 123
      # try_catch returns: {:error, {:not_found, :user, 123}}

  This enables clean pattern matching on domain errors:

      case result do
        {:ok, user} -> handle_user(user)
        {:error, {:not_found, :user, id}} -> handle_not_found(id)
        {:error, %ArgumentError{}} -> handle_bad_input()
      end

  ## When to Implement

  Implement `IThrowable` for exceptions that represent **domain errors** -
  expected failures that are part of your business logic. Examples:

  - Validation failures
  - Resource not found
  - Permission denied
  - Business rule violations

  Leave the default behavior for **unexpected errors** - bugs or system
  failures where you want the full exception for debugging:

  - `ArgumentError`, `KeyError`, etc.
  - Database connection errors
  - External service failures
  """

  @fallback_to_any true

  @doc """
  Extract the error value from an exception.

  Returns the value that should appear in `{:error, value}` when
  `Throw.try_catch/1` processes a caught exception.
  """
  @spec unwrap(t) :: term()
  def unwrap(exception)
end

defimpl Skuld.Comp.IThrowable, for: Any do
  @doc """
  Default implementation - return the exception unchanged.

  This preserves the full exception struct for debugging unexpected errors.
  """
  def unwrap(exception), do: exception
end
