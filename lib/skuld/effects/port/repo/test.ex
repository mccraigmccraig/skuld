# Test executor for Port.Repo that records operations via Writer.
#
# Each operation is logged as a {op_name, args_list, return_value} tuple,
# making it straightforward to assert on the sequence of Repo calls.
#
# ## Usage
#
#     comp
#     |> Port.Repo.Test.with_handler(output: fn r, log -> {r, log} end)
#     |> Throw.with_handler()
#     |> Comp.run!()
#     #=> {result, [{:insert, [changeset], {:ok, struct}}, ...]}
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.Test do
    @moduledoc """
    Effectful test executor for `Port.Repo` that records operations via `Writer`.

    Each operation emits a `{op_name, args_list, return_value}` tuple to a
    Writer log, making it easy to assert on the exact sequence of Repo calls
    made during a computation.

    ## Write Operations

    Write operations (`insert`, `update`, `delete`) apply changeset changes
    to produce a struct and return `{:ok, struct}`. The changeset and result
    are both captured in the log entry.

    ## Bulk Operations

    `update_all` and `delete_all` return `{0, nil}` by default.

    ## Read Operations

    Read operations return sensible empty defaults (`nil`, `[]`, `false`).
    Override specific reads using `Port.with_fn_handler/2` or
    `Port.with_test_handler/2` for your domain contract.

    ## Log Format

    Each entry is a 3-tuple: `{operation_name, args_list, return_value}`:

        {:insert, [changeset], {:ok, %User{name: "Alice"}}}
        {:get, [User, 42], nil}
        {:delete, [record], {:ok, record}}

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
      * `:registry` — Additional `Port` registry entries to merge alongside
        the `Port.Repo` entry. Use this when the computation also uses other
        Port contracts. Example:

            Repo.Test.with_handler(comp,
              registry: %{MyApp.Queries => MyApp.Queries.TestImpl},
              output: fn r, log -> {r, log} end
            )
    """

    use Skuld.Syntax

    alias Skuld.Effects.Port
    alias Skuld.Effects.Port.Repo
    alias Skuld.Effects.Writer

    @behaviour Repo.Effectful

    @default_tag Repo

    # -----------------------------------------------------------------
    # Write Operations
    # -----------------------------------------------------------------

    @impl true
    def insert(changeset) do
      comp do
        result = {:ok, safe_apply_changes(changeset)}
        _ <- Writer.tell(@default_tag, {:insert, [changeset], result})
        result
      end
    end

    @impl true
    def update(changeset) do
      comp do
        result = {:ok, safe_apply_changes(changeset)}
        _ <- Writer.tell(@default_tag, {:update, [changeset], result})
        result
      end
    end

    @impl true
    def delete(record) do
      comp do
        result = {:ok, record}
        _ <- Writer.tell(@default_tag, {:delete, [record], result})
        result
      end
    end

    # -----------------------------------------------------------------
    # Bulk Operations
    # -----------------------------------------------------------------

    @impl true
    def update_all(queryable, updates, opts) do
      comp do
        result = {0, nil}
        _ <- Writer.tell(@default_tag, {:update_all, [queryable, updates, opts], result})
        result
      end
    end

    @impl true
    def delete_all(queryable, opts) do
      comp do
        result = {0, nil}
        _ <- Writer.tell(@default_tag, {:delete_all, [queryable, opts], result})
        result
      end
    end

    # -----------------------------------------------------------------
    # Read Operations
    # -----------------------------------------------------------------

    @impl true
    def get(queryable, id) do
      comp do
        result = nil
        _ <- Writer.tell(@default_tag, {:get, [queryable, id], result})
        result
      end
    end

    @impl true
    def get!(queryable, id) do
      comp do
        result = nil
        _ <- Writer.tell(@default_tag, {:get!, [queryable, id], result})
        result
      end
    end

    @impl true
    def get_by(queryable, clauses) do
      comp do
        result = nil
        _ <- Writer.tell(@default_tag, {:get_by, [queryable, clauses], result})
        result
      end
    end

    @impl true
    def get_by!(queryable, clauses) do
      comp do
        result = nil
        _ <- Writer.tell(@default_tag, {:get_by!, [queryable, clauses], result})
        result
      end
    end

    @impl true
    def one(queryable) do
      comp do
        result = nil
        _ <- Writer.tell(@default_tag, {:one, [queryable], result})
        result
      end
    end

    @impl true
    def one!(queryable) do
      comp do
        result = nil
        _ <- Writer.tell(@default_tag, {:one!, [queryable], result})
        result
      end
    end

    @impl true
    def all(queryable) do
      comp do
        result = []
        _ <- Writer.tell(@default_tag, {:all, [queryable], result})
        result
      end
    end

    @impl true
    def exists?(queryable) do
      comp do
        result = false
        _ <- Writer.tell(@default_tag, {:exists?, [queryable], result})
        result
      end
    end

    @impl true
    def aggregate(queryable, aggregate, field) do
      comp do
        result = nil
        _ <- Writer.tell(@default_tag, {:aggregate, [queryable, aggregate, field], result})
        result
      end
    end

    # -----------------------------------------------------------------
    # Handler Installation
    # -----------------------------------------------------------------

    @doc """
    Install a test handler that wires both `Port` and `Writer` effects.

    Registers this module as the effectful executor for `Port.Repo` and
    installs a `Writer` handler to capture the operation log.

    ## Options

      * `:output` — Transform function `(result, log) -> output` passed
        through to `Writer.with_handler/3`. Without this, the log is
        discarded and only the computation result is returned.
      * `:registry` — Additional `Port` registry entries to merge alongside
        the `Port.Repo` entry. Since `Port.with_handler/2` scopes shadow
        each other, use this when the computation uses other Port contracts:

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
        #=> {result, [{:insert, [changeset], {:ok, struct}}, ...]}
    """
    @spec with_handler(Skuld.Comp.Types.computation(), keyword()) ::
            Skuld.Comp.Types.computation()
    def with_handler(comp, opts \\ []) do
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
        [tag: @default_tag]
        |> then(fn o -> if writer_output, do: Keyword.put(o, :output, writer_output), else: o end)

      comp
      |> Port.with_handler(registry)
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
