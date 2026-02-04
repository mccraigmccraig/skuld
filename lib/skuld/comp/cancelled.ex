defmodule Skuld.Comp.Cancelled do
  @moduledoc """
  Sentinel indicating a computation was cancelled.

  Like `Throw`, `Cancelled` goes through the leave_scope chain, allowing
  effects to clean up resources (close connections, release locks, etc.)
  when a computation is cancelled.

  ## Usage

  When cancelling a suspended computation, use `Skuld.Comp.cancel/2`:

      # Computation yielded a Suspend
      {%Suspend{} = suspend, env} = Comp.run(my_comp)

      # Cancel it (invokes leave_scope chain for cleanup)
      {%Cancelled{reason: :user_cancelled}, final_env} =
        Comp.cancel(suspend, env, :user_cancelled)

  ## Effect Cleanup

  Effects can detect cancellation in their `leave_scope` handler:

      def my_leave_scope(result, env) do
        case result do
          %Cancelled{reason: reason} ->
            cleanup_resources(reason)
            {result, env}

          _ ->
            {result, env}
        end
      end
  """

  @type t :: %__MODULE__{reason: term()}

  defstruct [:reason]

  defimpl Skuld.Comp.ISentinel do
    # Cancelled goes through leave_scope so effects can clean up
    def run(result, env), do: env.leave_scope.(result, env)

    def run!(%Skuld.Comp.Cancelled{reason: reason}) do
      raise "Computation cancelled: #{inspect(reason)}"
    end

    def sentinel?(_), do: true
    def suspend?(_), do: false
    def error?(_), do: true

    def serializable_payload(%Skuld.Comp.Cancelled{reason: reason}) do
      %{reason: reason}
    end
  end
end
