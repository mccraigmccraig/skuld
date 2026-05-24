defprotocol Skuld.ForeignResolver do
  @moduledoc """
  Protocol for resolving `ForeignSuspend` values across different platforms.

  Consumers (e.g., Hologram) implement this protocol with a platform-specific
  struct to resolve foreign suspensions. The protocol uses continuation-passing
  style — the resolver calls the `continuation` with a map of resolved values
  when ready, enabling both synchronous and asynchronous resolution.

  ## Example (synchronous, for tests)

      defmodule MyResolver do
        defstruct []
      end

      defimpl Skuld.ForeignResolver, for: MyResolver do
        def await_resolutions(_resolver, suspends, continuation) do
          resolved = Map.new(suspends, &{&1.id, :done})
          continuation.(resolved)
        end
      end

  ## Example (async, for Hologram)

      defimpl Skuld.ForeignResolver, for: Hologram.JSResolver do
        def await_resolutions(_resolver, suspends, continuation) do
          promises = Enum.map(suspends, & &1.payload)
          Promise.any(promises).then(fn result ->
            resolved = # ... build %{id => value} map
            continuation.(resolved)
          end)
        end
      end
  """

  @doc """
  Resolve the given foreign suspensions and call the continuation with a map
  of `%{suspend_id => resolved_value}`.

  The resolver must call `continuation.(resolved)` exactly once. It may do so
  synchronously (for test/BEAM resolvers) or asynchronously (for JS/Promise resolvers).
  """
  @spec await_resolutions(
          t(),
          [Skuld.Comp.ForeignSuspend.t()],
          (map() -> term())
        ) :: term()
  def await_resolutions(resolver, suspends, continuation)
end
