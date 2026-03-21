# The `query` macro for applicative-do style automatic batching.
#
# Analyses variable dependencies in a do-block and automatically groups
# independent computations into concurrent fiber batches via
# `FiberPool.spawn_await_all`. This gives users Haxl-style automatic
# batching without manual `FiberPool.fiber` + `await_all!` boilerplate.
#
# ## Usage
#
#     import Skuld.Query.QueryBlock
#
#     query do
#       user <- Users.get_user(id)
#       recent <- Orders.get_recent()
#       orders <- Orders.get_by_user(user.id)
#       {user, recent, orders}
#     end
#
# The macro analyses that `user` and `recent` are independent (neither
# references the other), while `orders` depends on `user`. It emits:
#
#     FiberPool.spawn_await_all([Users.get_user(id), Orders.get_recent()])
#     |> Comp.bind(fn [user, recent] ->
#       Comp.bind(Orders.get_by_user(user.id), fn orders ->
#         {user, recent, orders}
#       end)
#     end)
#
# ## Syntax
#
# Uses do-block syntax (like `comp`):
#
# - `var <- computation` — bind the result of an effectful computation
# - `var = expression` — pure binding (participates in dependency analysis)
# - Last expression is auto-lifted if not already a computation
#
# ## Requirements
#
# Requires a FiberPool handler to be installed.
#
# ## Differences from `comp`
#
# - `comp` is purely sequential (monadic bind chain)
# - `query` analyses dependencies and parallelises independent bindings
defmodule Skuld.Query.QueryBlock do
  @moduledoc """
  The `query` macro for applicative-do style automatic concurrent batching.

  Analyses `<-` bindings in a do-block for data independence, then groups
  independent computations into concurrent fiber batches via
  `FiberPool.spawn_await_all/1`. Dependent bindings are sequenced with
  `Comp.bind/2` as usual.

  This gives users Haxl-style automatic batching without manual
  `FiberPool.fiber` + `await_all!` boilerplate.

  ## Example

      query do
        user   <- Users.get_user(id)
        recent <- Orders.get_recent()
        orders <- Orders.get_by_user(user.id)
        {user, recent, orders}
      end

  Here `get_user` and `get_recent` are independent and run concurrently,
  while `get_by_user` depends on `user` and runs after the first batch.

  ## Syntax

  - `var <- computation` — effectful binding (auto-batched if independent)
  - `var = expression` — pure binding (participates in dependency analysis)
  - Last expression — auto-lifted to `Comp.pure` if not already a computation

  ## Requirements

  Requires a `FiberPool` handler to be installed.
  """

  @doc """
  Create a computation with automatic concurrent batching of independent bindings.

  See module documentation for details.
  """
  defmacro query(clauses) do
    do_block = Keyword.fetch!(clauses, :do)
    Skuld.Query.QueryBlock.Impl.compile(__CALLER__, do_block)
  end

  @doc """
  Define a public function whose body is a `query` block.

  ## Example

      defquery user_with_orders(id) do
        user <- Users.get_user(id)
        recent <- Orders.get_recent()
        orders <- Orders.get_by_user(user.id)
        {user, recent, orders}
      end

  This is equivalent to:

      def user_with_orders(id) do
        query do
          user <- Users.get_user(id)
          recent <- Orders.get_recent()
          orders <- Orders.get_by_user(user.id)
          {user, recent, orders}
        end
      end
  """
  defmacro defquery(call_ast, clauses) do
    Skuld.Query.QueryBlock.Impl.defquery(__CALLER__, call_ast, clauses)
  end

  @doc """
  Define a private function whose body is a `query` block.

  ## Example

      defqueryp internal_fetch(id) do
        user <- Users.get_user(id)
        orders <- Orders.get_by_user(user.id)
        {user, orders}
      end
  """
  defmacro defqueryp(call_ast, clauses) do
    Skuld.Query.QueryBlock.Impl.defqueryp(__CALLER__, call_ast, clauses)
  end

  defmodule Impl do
    @moduledoc false

    @doc false
    def defquery(caller, call_ast, clauses) do
      validate_clauses!(caller, clauses)
      do_block = Keyword.fetch!(clauses, :do)

      quote do
        def unquote(call_ast) do
          Skuld.Query.QueryBlock.query(do: unquote(do_block))
        end
      end
    end

    @doc false
    def defqueryp(caller, call_ast, clauses) do
      validate_clauses!(caller, clauses)
      do_block = Keyword.fetch!(clauses, :do)

      quote do
        defp unquote(call_ast) do
          Skuld.Query.QueryBlock.query(do: unquote(do_block))
        end
      end
    end

    defp validate_clauses!(caller, clauses) do
      valid_keys = [:do]
      actual_keys = Keyword.keys(clauses)

      unless :do in actual_keys do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "query block requires a do clause"
      end

      invalid = actual_keys -- valid_keys

      if invalid != [] do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "query block does not support #{Enum.map_join(invalid, ", ", &inspect/1)} clauses. " <>
              "Only :do is supported."
      end
    end

    @doc false
    def compile(caller, do_block) do
      exprs = extract_exprs(do_block)
      {bindings, final_expr} = split_bindings_and_final(caller, exprs)

      if bindings == [] do
        # No bindings — just the final expression, auto-lifted
        wrap_with_imports(final_expr)
      else
        parsed = parse_bindings(caller, bindings)
        batches = dependency_sort(parsed)
        code = emit_batched_code(batches, final_expr)
        wrap_with_imports(code)
      end
    end

    # Extract expressions from block AST
    defp extract_exprs({:__block__, _, exprs}), do: exprs
    defp extract_exprs(single), do: [single]

    # Split list of expressions into bindings + final expression.
    # The final expression is the last line if it's not a binding.
    defp split_bindings_and_final(caller, exprs) do
      case exprs do
        [] ->
          raise CompileError,
            file: caller.file,
            line: caller.line,
            description: "query block must contain at least one expression"

        [single] ->
          # Single expression — it's the final expression (no bindings)
          {[], single}

        _ ->
          {leading, [last]} = Enum.split(exprs, -1)

          case last do
            {:<-, _, _} ->
              # Last expression is a binding — auto-lift would produce the
              # bound value, which is fine. Treat it as a binding with
              # an implicit final of the bound variable.
              raise CompileError,
                file: caller.file,
                line: caller.line,
                description:
                  "query block must end with an expression, not a binding. " <>
                    "Add a final expression after the last `<-` binding."

            {:=, _, _} ->
              raise CompileError,
                file: caller.file,
                line: caller.line,
                description:
                  "query block must end with an expression, not an assignment. " <>
                    "Add a final expression after the last `=` binding."

            _ ->
              # Validate that all leading expressions are bindings
              Enum.each(leading, fn
                {:<-, _, _} ->
                  :ok

                {:=, _, _} ->
                  :ok

                other ->
                  line = extract_line(other, caller)

                  raise CompileError,
                    file: caller.file,
                    line: line,
                    description:
                      "bare expression in query block: `#{Macro.to_string(other) |> String.slice(0, 50)}`. " <>
                        "Only `pattern <- computation` or `pattern = expression` bindings are allowed " <>
                        "before the final expression."
              end)

              {leading, last}
          end
      end
    end

    defp extract_line(expr, caller) do
      case expr do
        {_op, meta, _args} when is_list(meta) ->
          Keyword.get(meta, :line, caller.line)

        _ ->
          caller.line
      end
    end

    # Parse each binding into a structured map
    defp parse_bindings(caller, bindings) do
      bindings
      |> Enum.with_index()
      |> Enum.map(fn {binding, idx} ->
        case binding do
          {:<-, _meta, [pattern, rhs]} ->
            vars = extract_bound_vars(pattern)

            %{
              index: idx,
              pattern: pattern,
              rhs: rhs,
              type: :effectful,
              bound_vars: vars
            }

          {:=, _meta, [pattern, rhs]} ->
            vars = extract_bound_vars(pattern)

            %{
              index: idx,
              pattern: pattern,
              rhs: rhs,
              type: :pure,
              bound_vars: vars
            }

          other ->
            raise CompileError,
              file: caller.file,
              line: caller.line,
              description:
                "invalid query binding: expected `var <- expr` or `var = expr`, " <>
                  "got: #{Macro.to_string(other)}"
        end
      end)
    end

    # Extract all variable names bound by a pattern
    defp extract_bound_vars(pattern) do
      {_ast, vars} =
        Macro.prewalk(pattern, MapSet.new(), fn
          # Pin operator — skip (pinned var is NOT being bound)
          {:^, _, _} = node, acc ->
            {node, acc}

          # Variable binding (not underscore, not pin)
          {name, _meta, context} = node, acc
          when is_atom(name) and is_atom(context) and name != :_ ->
            {node, MapSet.put(acc, name)}

          # Everything else
          node, acc ->
            {node, acc}
        end)

      vars
    end

    # Extract all free variable references from an expression
    defp extract_free_vars(expr) do
      {_ast, vars} =
        Macro.prewalk(expr, MapSet.new(), fn
          # Pin operator — the pinned var IS a reference
          {:^, _, [{name, _meta, context}]}, acc
          when is_atom(name) and is_atom(context) ->
            {{:__query_visited__, [], nil}, MapSet.put(acc, name)}

          # Variable reference
          {name, _meta, context} = node, acc
          when is_atom(name) and is_atom(context) and name != :_ ->
            {node, MapSet.put(acc, name)}

          node, acc ->
            {node, acc}
        end)

      vars
    end

    # Build dependency graph and topologically sort into batches
    defp dependency_sort(parsed_bindings) do
      # Map: variable_name -> binding_index
      var_to_binding =
        Enum.reduce(parsed_bindings, %{}, fn binding, acc ->
          Enum.reduce(binding.bound_vars, acc, fn var, inner_acc ->
            Map.put(inner_acc, var, binding.index)
          end)
        end)

      # For each binding, find which other bindings it depends on
      bindings_with_deps =
        Enum.map(parsed_bindings, fn binding ->
          free = extract_free_vars(binding.rhs)

          deps =
            free
            |> Enum.reduce(MapSet.new(), fn var, acc ->
              case Map.get(var_to_binding, var) do
                nil -> acc
                dep_idx when dep_idx != binding.index -> MapSet.put(acc, dep_idx)
                _ -> acc
              end
            end)

          Map.put(binding, :deps, deps)
        end)

      topo_sort_batches(bindings_with_deps)
    end

    # Kahn's algorithm adapted to produce batches of independent nodes
    defp topo_sort_batches(bindings) do
      by_index = Map.new(bindings, &{&1.index, &1})
      remaining = MapSet.new(Enum.map(bindings, & &1.index))
      do_topo_sort(by_index, remaining, MapSet.new(), [])
    end

    defp do_topo_sort(by_index, remaining, completed, batches) do
      if MapSet.size(remaining) == 0 do
        Enum.reverse(batches)
      else
        # Find all nodes whose deps are fully satisfied
        ready =
          remaining
          |> Enum.filter(fn idx ->
            binding = Map.fetch!(by_index, idx)
            MapSet.subset?(binding.deps, completed)
          end)
          |> Enum.sort()

        if ready == [] do
          # Cycle detected — fall back to sequential
          sequential =
            remaining
            |> Enum.sort()
            |> Enum.map(&[Map.fetch!(by_index, &1)])

          Enum.reverse(batches) ++ sequential
        else
          batch = Enum.map(ready, &Map.fetch!(by_index, &1))
          new_completed = Enum.reduce(ready, completed, &MapSet.put(&2, &1))
          new_remaining = Enum.reduce(ready, remaining, &MapSet.delete(&2, &1))
          do_topo_sort(by_index, new_remaining, new_completed, [batch | batches])
        end
      end
    end

    # Emit the final code for all batches + final expression
    defp emit_batched_code(batches, final_expr) do
      # Build from inside out: start with the final expr, wrap with each batch
      batches
      |> Enum.reverse()
      |> Enum.reduce(final_expr, &emit_batch/2)
    end

    # Emit code for a single batch of bindings.
    # Effectful bindings are wrapped in FiberPool.fiber + await! because
    # query computations may use InternalSuspend.batch for batched data
    # fetching, which requires a fiber/scheduler context.
    defp emit_batch([single], inner) do
      case single.type do
        :effectful ->
          quote do
            Skuld.Comp.bind(
              Skuld.Comp.bind(
                Skuld.Effects.FiberPool.fiber(unquote(single.rhs)),
                &Skuld.Effects.FiberPool.await!/1
              ),
              fn unquote(single.pattern) ->
                unquote(inner)
              end
            )
          end

        :pure ->
          quote do
            unquote(single.pattern) = unquote(single.rhs)
            unquote(inner)
          end
      end
    end

    defp emit_batch(batch, inner) when length(batch) > 1 do
      {effectful, pure} = Enum.split_with(batch, &(&1.type == :effectful))

      case {effectful, pure} do
        {[], pure_only} ->
          emit_pure_bindings(pure_only, inner)

        {effectful, []} ->
          emit_spawn_await_all(effectful, inner)

        {effectful, pure} ->
          emit_pure_bindings(pure, emit_spawn_await_all(effectful, inner))
      end
    end

    defp emit_pure_bindings([], inner), do: inner

    defp emit_pure_bindings([binding | rest], inner) do
      quote do
        unquote(binding.pattern) = unquote(binding.rhs)
        unquote(emit_pure_bindings(rest, inner))
      end
    end

    defp emit_spawn_await_all(effectful, inner) do
      comps = Enum.map(effectful, & &1.rhs)
      patterns = Enum.map(effectful, & &1.pattern)

      # Use fiber_all + await_all! explicitly rather than spawn_await_all,
      # because spawn_await_all has a single-element optimization that skips
      # fiber wrapping, but query computations need fiber context for
      # InternalSuspend.batch to work.
      quote do
        Skuld.Comp.bind(
          Skuld.Comp.bind(
            Skuld.Effects.FiberPool.fiber_all(unquote(comps)),
            &Skuld.Effects.FiberPool.await_all!/1
          ),
          fn unquote(patterns) ->
            unquote(inner)
          end
        )
      end
    end

    defp wrap_with_imports(code) do
      quote do
        import Skuld.Comp.BaseOps
        unquote(code)
      end
    end
  end
end
