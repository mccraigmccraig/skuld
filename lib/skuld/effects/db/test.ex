# Test handler for DB effect that records calls and returns stubbed results.
#
# Uses Writer effect internally to accumulate all DB operations,
# allowing tests to verify what persistence calls were made.
#
# ## Usage
#
#     use Skuld.Syntax
#     alias Skuld.Comp
#     alias Skuld.Effects.DB
#
#     # Basic usage - returns {result, calls}
#     {result, calls} =
#       my_comp
#       |> DB.Test.with_handler(fn
#         %DB.Insert{input: cs} -> Ecto.Changeset.apply_changes(cs)
#         %DB.Update{input: cs} -> Ecto.Changeset.apply_changes(cs)
#         %DB.Delete{input: s} -> {:ok, s}
#       end)
#       |> Comp.run!()
#
#     assert [{:insert, changeset}] = calls
#
#     # Custom output transform
#     result =
#       my_comp
#       |> DB.Test.with_handler(
#         handler: fn op -> handle_op(op) end,
#         output: fn result, _calls -> result end  # discard calls
#       )
#       |> Comp.run!()
#
# ## Call Recording
#
# Each operation is recorded as a tuple `{operation_type, input_or_details}`:
#
# - `{:insert, changeset}` - single insert
# - `{:update, changeset}` - single update
# - `{:upsert, changeset}` - single upsert
# - `{:delete, struct_or_changeset}` - single delete
# - `{:insert_all, {schema, entries, opts}}` - bulk insert
# - `{:update_all, {schema, entries, opts}}` - bulk update
# - `{:upsert_all, {schema, entries, opts}}` - bulk upsert
# - `{:delete_all, {schema, entries, opts}}` - bulk delete
# - `{:transact, :ok}` - transaction (inner comp ran successfully)
# - `{:rollback, reason}` - explicit rollback
#
# Calls are returned in chronological order (first call first).
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.DB.Test do
    @moduledoc false

    @behaviour Skuld.Comp.IHandle

    alias Skuld.Comp
    alias Skuld.Comp.Env
    alias Skuld.Comp.Types
    alias Skuld.Effects.ChangeEvent
    alias Skuld.Effects.DB
    alias Skuld.Effects.Writer

    @writer_tag __MODULE__

    #############################################################################
    ## Handler Installation
    #############################################################################

    @doc """
    Install DB test handler.

    ## Options

    - `handler` - function to handle operations and return results (required unless
      passed as first argument)
    - `output` - function `(result, calls) -> final_result` (default: `&{&1, &2}`)

    ## Examples

        # Pass handler as first argument
        comp |> DB.Test.with_handler(fn op -> ... end) |> Comp.run!()

        # Pass handler in options
        comp |> DB.Test.with_handler(handler: fn op -> ... end) |> Comp.run!()

        # Custom output
        comp
        |> DB.Test.with_handler(
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
      |> Comp.with_handler(DB.sig(), &__MODULE__.handle/3)
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
        |> DB.Test.with_handler(&DB.Test.default_handler/1)
        |> Comp.run!()
    """
    @spec default_handler(struct()) :: term()
    def default_handler(%DB.Insert{input: input}) do
      apply_changes(input)
    end

    def default_handler(%DB.Update{input: input}) do
      apply_changes(input)
    end

    def default_handler(%DB.Upsert{input: input}) do
      apply_changes(input)
    end

    def default_handler(%DB.Delete{input: input}) do
      {:ok, get_struct(input)}
    end

    def default_handler(%DB.InsertAll{entries: entries, opts: opts}) do
      if Keyword.get(opts, :returning, false) do
        structs = Enum.map(entries, &apply_changes/1)
        {length(entries), structs}
      else
        {length(entries), nil}
      end
    end

    def default_handler(%DB.UpdateAll{entries: entries, opts: opts}) do
      if Keyword.get(opts, :returning, false) do
        structs = Enum.map(entries, &apply_changes/1)
        {length(entries), structs}
      else
        {length(entries), nil}
      end
    end

    def default_handler(%DB.UpsertAll{entries: entries, opts: opts}) do
      if Keyword.get(opts, :returning, false) do
        structs = Enum.map(entries, &apply_changes/1)
        {length(entries), structs}
      else
        {length(entries), nil}
      end
    end

    def default_handler(%DB.DeleteAll{entries: entries, opts: opts}) do
      if Keyword.get(opts, :returning, false) do
        structs = Enum.map(entries, &get_struct/1)
        {length(entries), structs}
      else
        {length(entries), nil}
      end
    end

    #############################################################################
    ## IHandler Implementation — Write Operations
    #############################################################################

    @impl Skuld.Comp.IHandle
    def handle(%DB.Insert{input: input} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:insert, normalize_input(input)}, result, env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle(%DB.Update{input: input} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:update, normalize_input(input)}, result, env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle(%DB.Upsert{input: input} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:upsert, normalize_input(input)}, result, env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle(%DB.Delete{input: input} = op, env, k) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:delete, normalize_input(input)}, result, env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle(
          %DB.InsertAll{schema: schema, entries: entries, opts: opts} = op,
          env,
          k
        ) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:insert_all, {schema, entries, opts}}, result, env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle(
          %DB.UpdateAll{schema: schema, entries: entries, opts: opts} = op,
          env,
          k
        ) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:update_all, {schema, entries, opts}}, result, env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle(
          %DB.UpsertAll{schema: schema, entries: entries, opts: opts} = op,
          env,
          k
        ) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:upsert_all, {schema, entries, opts}}, result, env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle(
          %DB.DeleteAll{schema: schema, entries: entries, opts: opts} = op,
          env,
          k
        ) do
      handler = get_handler!(env)
      result = handler.(op)
      record_and_continue({:delete_all, {schema, entries, opts}}, result, env, k)
    end

    #############################################################################
    ## IHandler Implementation — Transaction Operations
    #############################################################################

    @impl Skuld.Comp.IHandle
    def handle(%DB.Transact{comp: inner_comp}, env, k) do
      # Run the inner computation directly (no actual transaction)
      # Install a handler for rollback inside the transaction
      wrapped =
        inner_comp
        |> Comp.with_handler(DB.sig(), fn
          %DB.Rollback{reason: reason}, e, _inner_k ->
            record_call({:rollback, reason}, e)
            |> then(fn new_env -> k.({:rolled_back, reason}, new_env) end)

          op, e, inner_k ->
            # Delegate write operations to the outer handler
            handle(op, e, inner_k)
        end)

      {result, result_env} = Comp.call(wrapped, env, &Comp.identity_k/2)
      record_call_and_continue({:transact, :ok}, result, result_env, k)
    end

    @impl Skuld.Comp.IHandle
    def handle(%DB.Rollback{}, _env, _k) do
      raise ArgumentError, """
      DB.rollback/1 called outside of a transaction.

      rollback/1 must be called within a DB.transact/1 block.
      """
    end

    #############################################################################
    ## Private Helpers
    #############################################################################

    defp get_handler!(env) do
      Env.get_state!(env, {__MODULE__, :handler})
    end

    defp record_and_continue(call, result, env, k) do
      new_env = record_call(call, env)
      k.(result, new_env)
    end

    defp record_call_and_continue(call, result, env, k) do
      new_env = record_call(call, env)
      k.(result, new_env)
    end

    defp record_call(call, env) do
      # Directly update Writer state (same as Writer.tell handler does)
      sk = Writer.state_key(@writer_tag)
      current = Env.get_state(env, sk, [])
      updated = [call | current]
      Env.put_state(env, sk, updated)
    end

    # Normalize input to extract changeset from ChangeEvent
    defp normalize_input(%ChangeEvent{changeset: cs}), do: cs
    defp normalize_input(input), do: input

    # Apply changes to get struct
    defp apply_changes(%ChangeEvent{changeset: cs}) do
      Ecto.Changeset.apply_changes(cs)
    end

    defp apply_changes(%Ecto.Changeset{} = cs) do
      Ecto.Changeset.apply_changes(cs)
    end

    defp apply_changes(%{} = map), do: map

    # Get struct from input
    defp get_struct(%ChangeEvent{changeset: cs}) do
      Ecto.Changeset.apply_changes(cs)
    end

    defp get_struct(%Ecto.Changeset{} = cs) do
      Ecto.Changeset.apply_changes(cs)
    end

    defp get_struct(%{__struct__: _} = struct), do: struct
  end
end
