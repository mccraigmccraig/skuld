defmodule Skuld.Effects.Throw do
  @moduledoc """
  Throw/Catch effects - error handling with scoped catching.

  Uses the `%Skuld.Comp.Throw{}` struct as the error result type, which
  is intercepted by `catch_error` via leave_scope.

  ## Architecture

  - `throw(error)` returns `%Throw{error: error}` as the result
  - `catch_error` installs a leave_scope that intercepts `%Throw{}` results
  - When caught, the recovery computation runs and continues normal flow
  - Normal completion passes through unchanged
  - If recovery re-throws, the error propagates to outer catch handlers
  """

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IIntercept
  @behaviour Skuld.Comp.IInstall

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Throwable
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Throw, [:error])

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Throw an error - does not resume"
  @spec throw(term()) :: Types.computation()
  def throw(error) do
    Comp.effect(@sig, %Throw{error: error})
  end

  @doc """
  Catch errors from a sub-computation.

  If the sub-computation throws, the error handler is invoked and its result
  continues through normal flow (the continuation chain). This allows catch
  to fully recover from errors - subsequent binds will receive the recovery value.

  If the recovery computation itself throws, that error propagates through
  the leave_scope chain to any outer catch handlers.

  Normal completion passes through unchanged (no wrapping).

  ## Example

      # Transparent recovery - catch fully handles the error
      Throw.catch_error(
        risky_computation(),
        fn :not_found -> Comp.pure(:default) end
      )
      # Returns either the value or :default

      # Nested catch - inner catches first, unhandled propagates to outer
      Throw.catch_error(
        Throw.catch_error(inner, fn :a -> ... end),
        fn :b -> ... end
      )
  """
  @spec catch_error(Types.computation(), (term() -> Types.computation())) :: Types.computation()
  def catch_error(comp, error_handler) do
    fn env, outer_k ->
      previous_leave_scope = Env.get_leave_scope(env)

      catch_leave_scope = fn result, inner_env ->
        case result do
          %Comp.Throw{error: error} ->
            # CAUGHT! Restore previous leave_scope and run recovery
            restored_env = Env.with_leave_scope(inner_env, previous_leave_scope)

            # Run recovery computation through Comp.call so exceptions are caught
            {recovery_result, recovery_env} =
              Comp.call(error_handler.(error), restored_env, fn v, e -> {v, e} end)

            case recovery_result do
              %Comp.Throw{} = rethrown ->
                # Recovery re-threw - propagate through leave_scope chain
                # This allows outer catches to intercept it
                previous_leave_scope.(rethrown, recovery_env)

              other ->
                # Recovery succeeded - continue through NORMAL flow (outer_k)
                # This allows subsequent binds to receive the recovered value
                outer_k.(other, recovery_env)
            end

          other ->
            # Normal completion - pass through unchanged
            previous_leave_scope.(other, inner_env)
        end
      end

      modified_env = Env.with_leave_scope(env, catch_leave_scope)
      # Use Comp.call so exceptions in comp are caught with the correct env
      # (which has catch_leave_scope installed)
      Comp.call(comp, modified_env, outer_k)
    end
  end

  @doc """
  Catch and return Either-style result.

  Wraps both success and error paths for uniform handling:
  - Success: `{:ok, value}`
  - Error: `{:error, error}`

  ## Exception Handling

  When exceptions are raised inside computations, they are caught and converted
  to `{:error, unwrapped_value}`. The `Skuld.Comp.Throwable` protocol determines
  how exceptions are unwrapped:

  - By default, exceptions are returned as-is (e.g., `{:error, %ArgumentError{}}`)
  - Domain exceptions can implement `Throwable` to return cleaner error values

  For other exception kinds:
  - `:throw` values become `{:error, {:thrown, value}}`
  - `:exit` reasons become `{:error, {:exit, reason}}`

  ## Example

      result = Throw.try_catch(risky_computation())
      case result do
        {:ok, value} -> handle_success(value)
        {:error, %ArgumentError{}} -> handle_bad_input()
        {:error, {:not_found, id}} -> handle_not_found(id)
      end

  ## Throwable Protocol

  Implement `Skuld.Comp.Throwable` for domain exceptions to get clean error values:

      defimpl Skuld.Comp.Throwable, for: MyApp.NotFoundError do
        def unwrap(%{entity: entity, id: id}), do: {:not_found, entity, id}
      end
  """
  @spec try_catch(Types.computation()) :: Types.computation()
  def try_catch(comp) do
    catch_error(
      Comp.map(comp, fn value -> {:ok, value} end),
      fn error -> Comp.pure({:error, unwrap_error(error)}) end
    )
  end

  # Unwrap caught errors for try_catch
  defp unwrap_error(%{kind: :error, payload: exception}) do
    Throwable.unwrap(exception)
  end

  defp unwrap_error(%{kind: :throw, payload: value}) do
    {:thrown, value}
  end

  defp unwrap_error(%{kind: :exit, payload: reason}) do
    {:exit, reason}
  end

  defp unwrap_error(other) do
    # Direct Throw.throw values pass through unchanged
    other
  end

  @doc """
  Intercept thrown errors locally within a computation.

  This is the `IIntercept.intercept/2` implementation for Throw, enabling
  `{Throw, pattern}` clauses in `comp` block `catch` sections.

  Delegates to `catch_error/2`.
  """
  @impl Skuld.Comp.IIntercept
  @spec intercept(Types.computation(), (term() -> Types.computation())) :: Types.computation()
  defdelegate intercept(comp, handler), to: __MODULE__, as: :catch_error

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped Throw handler for a computation.

  Installs the Throw handler for the duration of `comp`. The handler is
  restored/removed when `comp` completes or throws.

  The argument order is pipe-friendly.

  ## Example

      # Wrap a computation with Throw handling
      comp_with_throw =
        comp do
          result <- risky_operation()
          return(result)
        end
        |> Throw.with_handler()

      # Compose with other handlers
      my_comp
      |> Throw.with_handler()
      |> State.with_handler(0)
      |> Comp.run(Env.new())
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, @sig, &__MODULE__.handle/3)
  end

  @doc """
  Install Throw handler via catch clause syntax.

  Config is ignored (Throw handler takes no configuration):

      catch
        Throw -> nil
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, _config), do: with_handler(comp)

  #############################################################################
  ## IHandle Implementation
  #############################################################################

  @doc "Default handler - return Throw struct as result (does not call k)"
  @impl Skuld.Comp.IHandle
  def handle(%Throw{error: error}, env, _k) do
    {%Comp.Throw{error: error}, env}
  end
end
