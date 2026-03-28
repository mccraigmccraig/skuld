# Test executor for Port.Repo that provides default return values.
#
# Logging is handled by Port-level :log option — each dispatch emits
# {mod, name, args, result} to a Writer tag automatically.
#
# ## Usage
#
#     comp
#     |> Port.Repo.Test.with_handler(output: fn r, log -> {r, log} end)
#     |> Throw.with_handler()
#     |> Comp.run!()
#     #=> {result, [{Port.Repo, :insert, [changeset], {:ok, struct}}, ...]}
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.Test do
    @moduledoc """
    Test executor for `Port.Repo` with automatic dispatch logging via Port.

    Write operations (`insert`, `update`, `delete`) apply changeset changes
    to produce a struct and return `{:ok, struct}`. Read operations return
    sensible empty defaults (`nil`, `[]`, `false`). Bulk operations return
    `{0, nil}`.

    Logging is handled by Port's built-in `:log` option — every Port dispatch
    (not just Repo operations) emits a `{mod, name, args, result}` 4-tuple
    to a Writer tag. `with_handler/2` wires this up automatically.

    ## Log Format

    Each entry is a 4-tuple: `{module, operation, args_list, return_value}`:

        {Port.Repo, :insert, [changeset], {:ok, %User{name: "Alice"}}}
        {Port.Repo, :get, [User, 42], nil}
        {Port.Repo, :delete, [record], {:ok, record}}

    ## Handler Installation

        alias Skuld.Effects.Port.Repo

        comp
        |> Repo.Test.with_handler(output: fn result, log -> {result, log} end)
        |> Throw.with_handler()
        |> Comp.run!()
        #=> {result, log_entries}

    ## Options

      * `:output` — Transform function `(result, log) -> output` passed to
        `Writer.with_handler/3`. Use `fn r, log -> {r, log} end` to capture
        the log alongside the result.
      * `:tag` — Writer tag for the log. Defaults to `Skuld.Effects.Port`.
        Use this when you need to distinguish multiple Port logs or avoid
        collisions with other Writer tags.
      * `:registry` — Additional `Port` registry entries to merge alongside
        the `Port.Repo` entry. Example:

            Repo.Test.with_handler(comp,
              registry: %{MyApp.Queries => MyApp.Queries.TestImpl},
              output: fn r, log -> {r, log} end
            )
    """

    alias Skuld.Comp
    alias Skuld.Effects.Port
    alias Skuld.Effects.Port.Repo
    alias Skuld.Effects.Writer

    @behaviour Repo.Effectful

    @default_tag Port

    # -----------------------------------------------------------------
    # Write Operations
    # -----------------------------------------------------------------

    @impl true
    def insert(changeset) do
      Comp.pure({:ok, safe_apply_changes(changeset)})
    end

    @impl true
    def update(changeset) do
      Comp.pure({:ok, safe_apply_changes(changeset)})
    end

    @impl true
    def delete(record) do
      Comp.pure({:ok, record})
    end

    # -----------------------------------------------------------------
    # Bulk Operations
    # -----------------------------------------------------------------

    @impl true
    def update_all(_queryable, _updates, _opts) do
      Comp.pure({0, nil})
    end

    @impl true
    def delete_all(_queryable, _opts) do
      Comp.pure({0, nil})
    end

    # -----------------------------------------------------------------
    # Read Operations
    # -----------------------------------------------------------------

    @impl true
    def get(_queryable, _id), do: Comp.pure(nil)

    @impl true
    def get!(_queryable, _id), do: Comp.pure(nil)

    @impl true
    def get_by(_queryable, _clauses), do: Comp.pure(nil)

    @impl true
    def get_by!(_queryable, _clauses), do: Comp.pure(nil)

    @impl true
    def one(_queryable), do: Comp.pure(nil)

    @impl true
    def one!(_queryable), do: Comp.pure(nil)

    @impl true
    def all(_queryable), do: Comp.pure([])

    @impl true
    def exists?(_queryable), do: Comp.pure(false)

    @impl true
    def aggregate(_queryable, _aggregate_fn, _field), do: Comp.pure(nil)

    # -----------------------------------------------------------------
    # Handler Installation
    # -----------------------------------------------------------------

    @doc """
    Install a test handler that wires `Port` (with logging) and `Writer`.

    Registers this module as the effectful executor for `Port.Repo` and
    enables Port-level logging via the `:log` option. A `Writer` handler
    captures the log entries.

    ## Options

      * `:output` — Transform function `(result, log) -> output` passed
        through to `Writer.with_handler/3`. Without this, the log is
        discarded and only the computation result is returned.
      * `:tag` — Writer tag for the log. Defaults to `Skuld.Effects.Port`.
        Use this when you need to distinguish multiple Port logs or avoid
        collisions with other Writer tags.
      * `:registry` — Additional `Port` registry entries to merge alongside
        the `Port.Repo` entry. Since nested `Port.with_handler/2` calls
        merge registries (inner wins on conflict), you can also register
        extra Port contracts via an outer `with_handler` call. This option
        is a convenience for passing them inline:

            Repo.Test.with_handler(comp,
              registry: %{MyApp.Queries => MyApp.Queries.TestImpl},
              output: fn r, log -> {r, log} end
            )

    ## Example

        alias Skuld.Effects.Port.Repo

        comp
        |> Repo.Test.with_handler(output: fn result, log -> {result, log} end)
        |> Throw.with_handler()
        |> Comp.run!()
        #=> {result, [{Port.Repo, :insert, [changeset], {:ok, struct}}, ...]}
    """
    @spec with_handler(Skuld.Comp.Types.computation(), keyword()) ::
            Skuld.Comp.Types.computation()
    def with_handler(comp, opts \\ []) do
      tag = Keyword.get(opts, :tag, @default_tag)
      output = Keyword.get(opts, :output)
      extra_registry = Keyword.get(opts, :registry, %{})

      registry = Map.put(extra_registry, Repo, {:effectful, __MODULE__})

      # Build Writer opts — always reverse the log (Writer stores newest-first)
      writer_output =
        if output do
          fn result, raw_log -> output.(result, Enum.reverse(raw_log)) end
        else
          nil
        end

      writer_opts =
        [tag: tag]
        |> then(fn o -> if writer_output, do: Keyword.put(o, :output, writer_output), else: o end)

      comp
      |> Port.with_handler(registry, log: tag)
      |> Writer.with_handler([], writer_opts)
    end

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------

    defp safe_apply_changes(%Ecto.Changeset{} = changeset) do
      Ecto.Changeset.apply_changes(changeset)
    end
  end
end
