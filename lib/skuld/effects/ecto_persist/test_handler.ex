if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.EctoPersist.TestHandler do
    @moduledoc """
    Test handler for EctoPersist effect that records calls and returns stubbed results.

    Uses Writer effect internally to accumulate all EctoPersist operations,
    allowing tests to verify what persistence calls were made.

    ## Usage

        use Skuld.Syntax
        alias Skuld.Comp
        alias Skuld.Effects.EctoPersist

        # Basic usage - returns {result, calls}
        {result, calls} =
          my_comp
          |> EctoPersist.with_test_handler(fn
            %EctoPersist.Insert{input: cs} -> Ecto.Changeset.apply_changes(cs)
            %EctoPersist.Update{input: cs} -> Ecto.Changeset.apply_changes(cs)
            %EctoPersist.Delete{input: s} -> {:ok, s}
          end)
          |> Comp.run!()

        assert [{:insert, changeset}] = calls

        # Custom output transform
        result =
          my_comp
          |> EctoPersist.with_test_handler(
            handler: fn op -> handle_op(op) end,
            output: fn result, _calls -> result end  # discard calls
          )
          |> Comp.run!()

    ## Call Recording

    Each operation is recorded as a tuple `{operation_type, input_or_details}`:

    - `{:insert, changeset}` - single insert
    - `{:update, changeset}` - single update
    - `{:upsert, changeset}` - single upsert
    - `{:delete, struct_or_changeset}` - single delete
    - `{:insert_all, {schema, entries, opts}}` - bulk insert
    - `{:update_all, {schema, entries, opts}}` - bulk update
    - `{:upsert_all, {schema, entries, opts}}` - bulk upsert
    - `{:delete_all, {schema, entries, opts}}` - bulk delete

    Calls are returned in chronological order (first call first).
    """

    @behaviour Skuld.Comp.IHandler

    alias Skuld.Comp
    alias Skuld.Comp.Env
    alias Skuld.Comp.Types
    alias Skuld.Effects.EctoPersist
    alias Skuld.Effects.Writer

    @sig EctoPersist
    @writer_tag __MODULE__

    @doc """
    Install EctoPersist test handler.

    ## Options

    - `handler` - function to handle operations and return results (required unless
      passed as first argument)
    - `output` - function `(result, calls) -> final_result` (default: `&{&1, &2}`)

    ## Examples

        # Pass handler as first argument
        comp |> EctoPersist.with_test_handler(fn op -> ... end) |> Comp.run!()

        # Pass handler in options
        comp |> EctoPersist.with_test_handler(handler: fn op -> ... end) |> Comp.run!()

        # Custom output
        comp
        |> EctoPersist.with_test_handler(
          handler: fn op -> ... end,
          output: fn result, calls -> %{result: result, calls: calls} end
        )
        |> Comp.run!()
    """
    @spec with_handler(Types.computation(), (struct() -> term()) | keyword()) ::
            Types.computation()
    def with_handler(comp, handler_or_opts)

    def with_handler(comp, handler) when is_function(handler, 1) do
      with_handler(comp, handler: handler)
    end

    def with_handler(comp, opts) when is_list(opts) do
      handler = Keyword.fetch!(opts, :handler)
      output_fn = Keyword.get(opts, :output, &{&1, &2})

      state_key = {__MODULE__, :handler}

      comp
      |> Comp.scoped(fn env ->
        modified = Env.put_state(env, state_key, handler)

        finally_k = fn value, e ->
          restored = %{e | state: Map.delete(e.state, state_key)}
          {value, restored}
        end

        {modified, finally_k}
      end)
      |> Comp.with_handler(@sig, &__MODULE__.handle/3)
      |> Writer.with_handler([],
        tag: @writer_tag,
        output: fn result, calls ->
          # Reverse calls to chronological order (Writer prepends)
          output_fn.(result, Enum.reverse(calls))
        end
      )
    end

    @doc """
    Default handler that applies changes to changesets and returns reasonable defaults.

    Useful when you don't care about specific return values:

        comp
        |> EctoPersist.with_test_handler(&EctoPersist.TestHandler.default_handler/1)
        |> Comp.run!()
    """
    @spec default_handler(struct()) :: term()
    def default_handler(%EctoPersist.Insert{input: input}) do
      apply_changes(input)
    end

    def default_handler(%EctoPersist.Update{input: input}) do
      apply_changes(input)
    end

    def default_handler(%EctoPersist.Upsert{input: input}) do
      apply_changes(input)
    end

    def default_handler(%EctoPersist.Delete{input: input}) do
      {:ok, get_struct(input)}
    end

    def default_handler(%EctoPersist.InsertAll{entries: entries, opts: opts}) do
      if Keyword.get(opts, :returning, false) do
        structs = Enum.map(entries, &apply_changes/1)
        {length(entries), structs}
      else
        {length(entries), nil}
      end
    end

    def default_handler(%EctoPersist.UpdateAll{entries: entries, opts: opts}) do
      if Keyword.get(opts, :returning, false) do
        structs = Enum.map(entries, &apply_changes/1)
        {length(entries), structs}
      else
        {length(entries), nil}
      end
    end

    def default_handler(%EctoPersist.UpsertAll{entries: entries, opts: opts}) do
      if Keyword.get(opts, :returning, false) do
        structs = Enum.map(entries, &apply_changes/1)
        {length(entries), structs}
      else
        {length(entries), nil}
      end
    end

    def default_handler(%EctoPersist.DeleteAll{entries: entries, opts: opts}) do
      if Keyword.get(opts, :returning, false) do
        structs = Enum.map(entries, &get_struct/1)
        {length(entries), structs}
      else
        {length(entries), nil}
      end
    end

    #############################################################################
    ## IHandler Implementation
    #############################################################################

    @impl Skuld.Comp.IHandler
    def handle(%EctoPersist.Insert{input: input} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:insert, normalize_input(input)}, result, env, k)
    end

    @impl Skuld.Comp.IHandler
    def handle(%EctoPersist.Update{input: input} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:update, normalize_input(input)}, result, env, k)
    end

    @impl Skuld.Comp.IHandler
    def handle(%EctoPersist.Upsert{input: input} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:upsert, normalize_input(input)}, result, env, k)
    end

    @impl Skuld.Comp.IHandler
    def handle(%EctoPersist.Delete{input: input} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:delete, normalize_input(input)}, result, env, k)
    end

    @impl Skuld.Comp.IHandler
    def handle(%EctoPersist.InsertAll{schema: schema, entries: entries, opts: opts} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:insert_all, {schema, entries, opts}}, result, env, k)
    end

    @impl Skuld.Comp.IHandler
    def handle(%EctoPersist.UpdateAll{schema: schema, entries: entries, opts: opts} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:update_all, {schema, entries, opts}}, result, env, k)
    end

    @impl Skuld.Comp.IHandler
    def handle(%EctoPersist.UpsertAll{schema: schema, entries: entries, opts: opts} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:upsert_all, {schema, entries, opts}}, result, env, k)
    end

    @impl Skuld.Comp.IHandler
    def handle(%EctoPersist.DeleteAll{schema: schema, entries: entries, opts: opts} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:delete_all, {schema, entries, opts}}, result, env, k)
    end

    #############################################################################
    ## Private Helpers
    #############################################################################

    defp get_handler!(env) do
      case Env.get_state(env, {__MODULE__, :handler}) do
        nil -> raise "EctoPersist.TestHandler handler not installed"
        handler -> handler
      end
    end

    defp record_and_continue(call, result, env, k) do
      # Directly update Writer state (same as Writer.tell handler does)
      state_key = {Writer, @writer_tag}
      current = Env.get_state(env, state_key, [])
      updated = [call | current]
      new_env = Env.put_state(env, state_key, updated)
      k.(result, new_env)
    end

    # Normalize input to extract changeset from EctoEvent
    defp normalize_input(%EctoPersist.EctoEvent{changeset: cs}), do: cs
    defp normalize_input(input), do: input

    # Apply changes to get struct
    defp apply_changes(%EctoPersist.EctoEvent{changeset: cs}) do
      Ecto.Changeset.apply_changes(cs)
    end

    defp apply_changes(%Ecto.Changeset{} = cs) do
      Ecto.Changeset.apply_changes(cs)
    end

    defp apply_changes(%{} = map), do: map

    # Get struct from input
    defp get_struct(%EctoPersist.EctoEvent{changeset: cs}) do
      Ecto.Changeset.apply_changes(cs)
    end

    defp get_struct(%Ecto.Changeset{} = cs) do
      Ecto.Changeset.apply_changes(cs)
    end

    defp get_struct(%{__struct__: _} = struct), do: struct
  end
end
