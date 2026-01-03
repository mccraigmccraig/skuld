defmodule Skuld.Effects.Bracket do
  @moduledoc """
  Bracket effect for safe resource acquisition and cleanup.

  Bracket ensures that resources are properly released even when errors occur.
  This is essential for managing resources like file handles, database connections,
  locks, and network connections.

  ## Overview

  The `bracket/3` function takes three arguments:
  - `acquire` - Computation that acquires a resource
  - `release_fn` - Function `(resource -> computation)` that releases the resource
  - `use_fn` - Function `(resource -> computation)` that uses the resource

  The release function is guaranteed to run exactly once, whether the use
  computation succeeds or throws an error.

  ## Example

      import Skuld.Syntax

      result <- Bracket.bracket(
        # Acquire resource
        comp do
          handle <- open_file("data.txt")
          return(handle)
        end,
        # Release (always runs)
        fn handle ->
          comp do
            _ <- close_file(handle)
            return(:ok)
          end
        end,
        # Use resource
        fn handle ->
          comp do
            content <- read_file(handle)
            return(process(content))
          end
        end
      )

  ## Error Handling

  If the use computation throws an error, the release function runs before
  the error is re-thrown:

      Bracket.bracket(
        acquire_connection(),
        fn conn -> release_connection(conn) end,
        fn conn ->
          comp do
            # If this throws, conn is still released
            result <- dangerous_operation(conn)
            return(result)
          end
        end
      )

  If the release function itself throws:
  - If the use computation succeeded, the release error propagates
  - If the use computation threw, the original error propagates (release error is suppressed)

  ## Nested Brackets

  Brackets can be nested. Each bracket manages its own resource independently:

      Bracket.bracket(
        acquire_outer(),
        fn outer -> release_outer(outer) end,
        fn outer ->
          comp do
            inner_result <- Bracket.bracket(
              acquire_inner(),
              fn inner -> release_inner(inner) end,
              fn inner -> use_both(outer, inner) end
            )
            return(inner_result)
          end
        end
      )

  Resources are released in LIFO order (inner first, then outer).

  ## Convenience Functions

  - `bracket/3` - Full bracket with acquire, release, and use
  - `bracket_/2` - Simplified bracket when acquire returns the resource directly
  - `finally/2` - Just ensure cleanup runs (no resource passing)
  """

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @doc """
  Acquire a resource, use it, and ensure it is released.

  The release function is guaranteed to run exactly once, whether the use
  computation succeeds or throws an error.

  ## Parameters

  - `acquire` - Computation that acquires a resource
  - `release_fn` - Function `(resource -> computation)` that releases the resource
  - `use_fn` - Function `(resource -> computation)` that uses the resource

  ## Returns

  A computation that returns the result of the use function.

  ## Example

      Bracket.bracket(
        comp do
          Logger.info("Acquiring lock")
          lock <- Lock.acquire(:my_lock)
          return(lock)
        end,
        fn lock ->
          comp do
            Logger.info("Releasing lock")
            _ <- Lock.release(lock)
            return(:ok)
          end
        end,
        fn lock ->
          comp do
            # Critical section - lock is held
            result <- do_work()
            return(result)
          end
        end
      )
  """
  @spec bracket(
          Types.computation(),
          (term() -> Types.computation()),
          (term() -> Types.computation())
        ) :: Types.computation()
  def bracket(acquire, release_fn, use_fn)
      when is_function(release_fn, 1) and is_function(use_fn, 1) do
    Comp.bind(acquire, fn resource ->
      with_release(resource, release_fn, use_fn)
    end)
  end

  # Internal: set up scoped release for an already-acquired resource
  #
  # We don't use Comp.scoped directly because we need to route Throws from
  # release through leave_scope so they can be caught by outer catch handlers.
  defp with_release(resource, release_fn, use_fn) do
    fn env, outer_k ->
      previous_leave_scope = Comp.Env.get_leave_scope(env)

      # Normal exit: run release, route result appropriately
      normal_k = fn value, inner_env ->
        {final_result, released_env} =
          run_release(resource, release_fn, value, inner_env)

        restored_env = Comp.Env.with_leave_scope(released_env, previous_leave_scope)

        case final_result do
          %Comp.Throw{} = throw ->
            # Release threw - route through leave_scope so catch can intercept
            previous_leave_scope.(throw, restored_env)

          _ ->
            # Success - continue through normal path
            outer_k.(final_result, restored_env)
        end
      end

      # Abnormal exit (throw from use): run release, continue through leave_scope
      my_leave_scope = fn result, inner_env ->
        {final_result, released_env} =
          run_release(resource, release_fn, result, inner_env)

        restored_env = Comp.Env.with_leave_scope(released_env, previous_leave_scope)
        previous_leave_scope.(final_result, restored_env)
      end

      modified_env = Comp.Env.with_leave_scope(env, my_leave_scope)
      Comp.call(use_fn.(resource), modified_env, normal_k)
    end
  end

  # Run the release computation and determine final result
  defp run_release(resource, release_fn, original_result, env) do
    case Comp.call(release_fn.(resource), env, &Comp.identity_k/2) do
      {%Comp.Throw{} = release_error, released_env} ->
        # Release threw an error
        case original_result do
          %Comp.Throw{} ->
            # Original also threw - preserve original error, suppress release error
            {original_result, released_env}

          %Comp.Suspend{} ->
            # Original suspended - preserve suspension, suppress release error
            {original_result, released_env}

          _ ->
            # Original succeeded - propagate release error
            {release_error, released_env}
        end

      {_release_result, released_env} ->
        # Release succeeded - preserve original result
        {original_result, released_env}
    end
  end

  @doc """
  Simplified bracket when acquire computation directly returns the resource.

  This is a convenience wrapper when you don't need a separate acquire computation.

  ## Example

      # Instead of:
      Bracket.bracket(
        Comp.pure(file_handle),
        fn h -> close(h) end,
        fn h -> read(h) end
      )

      # You can write:
      Bracket.bracket_(
        file_handle,
        fn h -> close(h) end,
        fn h -> read(h) end
      )
  """
  @spec bracket_(
          term(),
          (term() -> Types.computation()),
          (term() -> Types.computation())
        ) :: Types.computation()
  def bracket_(resource, release_fn, use_fn)
      when is_function(release_fn, 1) and is_function(use_fn, 1) do
    with_release(resource, release_fn, use_fn)
  end

  @doc """
  Ensure cleanup runs after a computation, regardless of success or failure.

  This is like `bracket` but without resource passing - just ensures the
  cleanup computation runs.

  ## Example

      Bracket.finally(
        comp do
          _ <- Logger.info("Starting operation")
          result <- do_work()
          return(result)
        end,
        comp do
          _ <- Logger.info("Operation complete")
          return(:ok)
        end
      )
  """
  @spec finally(Types.computation(), Types.computation()) :: Types.computation()
  def finally(comp, cleanup) do
    fn env, outer_k ->
      previous_leave_scope = Comp.Env.get_leave_scope(env)

      # Run cleanup and determine final result
      run_cleanup = fn original_result, inner_env ->
        case Comp.call(cleanup, inner_env, &Comp.identity_k/2) do
          {%Comp.Throw{} = cleanup_error, cleaned_env} ->
            case original_result do
              %Comp.Throw{} -> {original_result, cleaned_env}
              %Comp.Suspend{} -> {original_result, cleaned_env}
              _ -> {cleanup_error, cleaned_env}
            end

          {_cleanup_result, cleaned_env} ->
            {original_result, cleaned_env}
        end
      end

      # Normal exit: run cleanup, route result appropriately
      normal_k = fn value, inner_env ->
        {final_result, cleaned_env} = run_cleanup.(value, inner_env)
        restored_env = Comp.Env.with_leave_scope(cleaned_env, previous_leave_scope)

        case final_result do
          %Comp.Throw{} = throw ->
            previous_leave_scope.(throw, restored_env)

          _ ->
            outer_k.(final_result, restored_env)
        end
      end

      # Abnormal exit: run cleanup, continue through leave_scope
      my_leave_scope = fn result, inner_env ->
        {final_result, cleaned_env} = run_cleanup.(result, inner_env)
        restored_env = Comp.Env.with_leave_scope(cleaned_env, previous_leave_scope)
        previous_leave_scope.(final_result, restored_env)
      end

      modified_env = Comp.Env.with_leave_scope(env, my_leave_scope)
      Comp.call(comp, modified_env, normal_k)
    end
  end
end
