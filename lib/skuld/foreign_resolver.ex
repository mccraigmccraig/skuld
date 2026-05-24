defprotocol Skuld.ForeignResolver do
  @moduledoc """
  Protocol for resolving `ForeignSuspend` values across different platforms.

  The protocol dispatches on the `payload` field of the first `ForeignSuspend`
  in the list. Consumers implement this protocol for their payload type to
  resolve foreign suspensions via platform-specific mechanisms (e.g., JS
  Promises, OS I/O completion ports).

  The protocol uses continuation-passing style — the implementation calls
  `continuation.(resolved)` with a map of `%{suspend_id => resolved_value}`
  when ready, enabling both synchronous and asynchronous resolution.

  ## Example (synchronous, for tests)

      defmodule MyPayload do
        defstruct [:value]
      end

      defimpl Skuld.ForeignResolver, for: MyPayload do
        def await_resolutions(suspends, continuation) do
          resolved = Map.new(suspends, &{&1.id, &1.payload.value})
          continuation.(resolved)
        end
      end

  ## Example (async, for Hologram)

      defimpl Skuld.ForeignResolver, for: Hologram.JS.PromiseRef do
        def await_resolutions(suspends, continuation) do
          promises = Enum.map(suspends, & &1.payload.promise)
          JS.Promise.all(promises).then(fn results ->
            resolved =
              suspends
              |> Enum.zip(results)
              |> Map.new(fn {s, val} -> {s.id, val} end)

            continuation.(resolved)
          end)
        end
      end
  """

  @doc """
  Resolve the given foreign suspensions and call the `continuation` with a map
  of `%{ForeignSuspend.id => resolved_value}`.

  The first parameter is any `ForeignSuspend.payload` value from the list,
  used for protocol dispatch. The full list of suspends is also passed so
  the implementation can batch-resolve them.

  The implementation must call `continuation.(resolved)` exactly once. It may
  do so synchronously or asynchronously.
  """
  @spec await_resolutions(
          payload :: term(),
          [Skuld.Comp.ForeignSuspend.t()],
          (map() -> term())
        ) :: term()
  def await_resolutions(payload, suspends, continuation)
end

defmodule Skuld.ForeignResolver.Runner do
  @moduledoc """
  Resolution loop for `ForeignSuspend` values.

  Runs a computation through the `ForeignResolver` protocol until all
  foreign suspensions are resolved and the computation completes.

  ## Example

      comp
      |> FiberPool.with_handler()
      |> ForeignResolver.Runner.run()
  """
  alias Skuld.Comp
  alias Skuld.Coroutine.Completed
  alias Skuld.Coroutine.ForeignSuspensions

  @doc """
  Run a computation through the foreign resolution loop.

  Returns the computation's final result once all foreign suspensions
  are resolved.
  """
  @spec run(Comp.Types.computation()) :: term()
  def run(comp) do
    {result, _env} = Comp.run(comp)

    case result do
      %ForeignSuspensions{} = fs ->
        resolve_loop(fs)

      other ->
        other
    end
  end

  defp resolve_loop(fs) do
    first_payload = hd(fs.suspensions).payload

    Skuld.ForeignResolver.await_resolutions(first_payload, fs.suspensions, fn resolved ->
      next = Skuld.Coroutine.call(fs, resolved)

      case next do
        %ForeignSuspensions{} = next_fs ->
          resolve_loop(next_fs)

        %Completed{result: result} ->
          result
      end
    end)
  end
end
