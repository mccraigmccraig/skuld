# The `alet` macro for applicative do-notation.
#
# Analyses variable dependencies between bindings and automatically
# parallelises independent computations using FiberPool fibers.
# This is the Elixir equivalent of Haskell's ApplicativeDo / the
# funcool/cats `alet` macro from Clojure.
#
# ## Usage
#
#     import Skuld.Comp.Alet
#
#     alet a <- fetch(:x),
#          b <- fetch(:y),
#          c <- pure(a + b) do
#       c * 2
#     end
#
# The macro analyses that `a` and `b` are independent (neither references
# the other), while `c` depends on both. It emits code equivalent to:
#
#     Comp.spawn_await_all([fetch(:x), fetch(:y)])
#     |> Comp.bind(fn [a, b] ->
#       pure(a + b)
#       |> Comp.map(fn c -> c * 2 end)
#     end)
#
# ## Requirements
#
# Requires a FiberPool handler to be installed (fibers are used for
# concurrent execution of independent bindings).
#
# ## Syntax
#
# - `var <- computation` — bind the result of an effectful computation
# - `var = expression` — pure binding (participates in dependency analysis)
# - The `do` block is the final expression, which may reference any binding
#
# Pattern matching in `<-` bindings is supported but note: complex patterns
# (tuples, maps, etc.) will work but the binding is treated as defining
# whichever variables appear in the pattern.
defmodule Skuld.Comp.Alet do
  @moduledoc false

  @doc """
  Applicative let — automatic parallelisation of independent bindings.

  Analyses variable dependencies between bindings and runs independent
  groups concurrently as FiberPool fibers, while preserving sequential
  ordering where data dependencies exist.

  ## Example

      alet a <- fetch_user(1),
           b <- fetch_user(2),
           c <- process(a, b) do
        format_result(c)
      end

  Here `fetch_user(1)` and `fetch_user(2)` run concurrently (they share
  no dependencies), while `process(a, b)` waits for both to complete.
  """
  # Elixir parses `alet a <- x, b <- y do body end` as a call with
  # multiple arguments: the bindings as positional args, and the do block
  # as a keyword list in the last argument position. We capture all args.
  defmacro alet({:<-, _, _} = single_binding, clauses) do
    do_alet(__CALLER__, [single_binding], clauses)
  end

  defmacro alet({:=, _, _} = single_binding, clauses) do
    do_alet(__CALLER__, [single_binding], clauses)
  end

  # For 2+ bindings, Elixir passes them as individual arguments with the
  # keyword clauses merged into the last one. We need to handle the
  # general case via unquote_splicing. Since Elixir doesn't support truly
  # variadic macros, we generate clauses for common arities.
  for n <- 2..20 do
    args = Macro.generate_arguments(n, __MODULE__)
    last_arg = List.last(args)
    binding_args = Enum.slice(args, 0..-2//1)

    defmacro alet(unquote_splicing(binding_args), unquote(last_arg)) do
      bindings_and_last = [unquote_splicing(binding_args), unquote(last_arg)]
      # The last positional arg might be a binding with clauses attached,
      # or it might itself be the clauses keyword list.
      {bindings, clauses} = Skuld.Comp.Alet.Impl.split_args(bindings_and_last)
      Skuld.Comp.Alet.Impl.do_alet(__CALLER__, bindings, clauses)
    end
  end

  defp do_alet(caller, bindings, clauses) do
    Skuld.Comp.Alet.Impl.do_alet(caller, bindings, clauses)
  end

  defmodule Impl do
    @moduledoc false

    @doc false
    def split_args(args) do
      # The last element is either:
      # 1. A keyword list [do: body] (when last binding + clauses)
      # 2. A binding (when clauses are separate)
      case List.last(args) do
        kw when is_list(kw) ->
          if Keyword.has_key?(kw, :do) do
            bindings = Enum.slice(args, 0..-2//1)
            {bindings, kw}
          else
            {args, []}
          end

        _ ->
          {args, []}
      end
    end

    @doc false
    def do_alet(caller, bindings, clauses) do
      do_block = Keyword.fetch!(clauses, :do)

      parsed = parse_bindings(caller, bindings)
      batches = dependency_sort(parsed)

      emit_batched_code(batches, do_block)
    end

    # Parse each binding into a map with pattern, rhs, type, and bound vars
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
                "invalid alet binding: expected `var <- expr` or `var = expr`, " <>
                  "got: #{Macro.to_string(other)}"
        end
      end)
    end

    # Extract all variable names bound by a pattern.
    defp extract_bound_vars(pattern) do
      {_ast, vars} =
        Macro.prewalk(pattern, MapSet.new(), fn
          # Pin operator — skip subtree (pinned var is NOT being bound)
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

    # Extract all free variable references from an expression.
    defp extract_free_vars(expr) do
      {_ast, vars} =
        Macro.prewalk(expr, MapSet.new(), fn
          # Pin operator — the pinned var IS a reference
          {:^, _, [{name, _meta, context}]}, acc
          when is_atom(name) and is_atom(context) ->
            {{:__alet_visited__, [], nil}, MapSet.put(acc, name)}

          # Variable reference
          {name, _meta, context} = node, acc
          when is_atom(name) and is_atom(context) and name != :_ ->
            {node, MapSet.put(acc, name)}

          node, acc ->
            {node, acc}
        end)

      vars
    end

    # Build dependency graph and topologically sort into batches.
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

    # Kahn's algorithm adapted to produce batches of independent nodes.
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

    # Emit the final code for all batches
    defp emit_batched_code(batches, do_block) do
      body = do_block

      # Build from inside out: start with the body, wrap with each batch
      batches
      |> Enum.reverse()
      |> Enum.reduce(body, &emit_batch/2)
      |> wrap_with_imports()
    end

    # Emit code for a single batch of bindings
    defp emit_batch([single], inner) do
      case single.type do
        :effectful ->
          quote do
            Skuld.Comp.bind(unquote(single.rhs), fn unquote(single.pattern) ->
              unquote(inner)
            end)
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
          emit_ap_all(effectful, inner)

        {effectful, pure} ->
          emit_pure_bindings(pure, emit_ap_all(effectful, inner))
      end
    end

    defp emit_pure_bindings([], inner), do: inner

    defp emit_pure_bindings([binding | rest], inner) do
      quote do
        unquote(binding.pattern) = unquote(binding.rhs)
        unquote(emit_pure_bindings(rest, inner))
      end
    end

    defp emit_ap_all(effectful, inner) do
      comps = Enum.map(effectful, & &1.rhs)
      patterns = Enum.map(effectful, & &1.pattern)
      list_pattern = patterns

      quote do
        Skuld.Comp.bind(
          Skuld.Comp.spawn_await_all(unquote(comps)),
          fn unquote(list_pattern) ->
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
