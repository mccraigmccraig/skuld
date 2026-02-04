# Shared utilities for effects that use Task.Supervisor for concurrency.
#
# Used by `Async` and `Parallel` effects.
defmodule Skuld.Effects.Helpers.TaskHelpers do
  @moduledoc false

  @doc """
  Stop a supervisor gracefully, ignoring exit signals if it's already stopped.

  Returns `:ok` regardless of whether the supervisor was running or already stopped.

  ## Example

      sup = Env.get_state(env, @supervisor_key)
      TaskHelpers.stop_supervisor(sup)
  """
  @spec stop_supervisor(pid() | nil) :: :ok
  def stop_supervisor(nil), do: :ok

  def stop_supervisor(sup) when is_pid(sup) do
    if Process.alive?(sup) do
      try do
        Supervisor.stop(sup, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
