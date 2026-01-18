defmodule Skuld.Comp.CompBlock do
  @moduledoc """
  The `comp` macro for monadic do-notation style effect composition.

  Provides `comp`, `defcomp`, and `defcompp` macros that transform
  arrow notation (`<-`) into `Skuld.Comp.bind` chains.

  ## Usage

      import Skuld.Comp.CompBlock

      comp do
        x <- State.get()
        y = x + 1
        _ <- State.put(y)
        return(y)
      end

  ## Syntax

  - `x <- effect()` - bind the result of an effectful computation
  - `x = expr` - pure variable binding (unchanged)
  - `return(value)` - lift a pure value (optional - values are auto-lifted)
  - Last expression is auto-lifted if not already a computation

  ## Auto-Lifting

  Non-computation values are automatically wrapped in `pure()`:

      comp do
        x <- State.get()
        _ <- if x > 5, do: Writer.tell(:big)  # nil auto-lifted when false
        x * 2  # final expression auto-lifted (no return needed)
      end

  ## Else Clause

  You can add an else clause to handle pattern match failures in `<-` bindings:

      comp do
        {:ok, x} <- maybe_returns_error()
        return(x)
      else
        {:error, reason} -> return({:failed, reason})
        other -> return({:unexpected, other})
      end

  When a pattern in `<-` fails to match, the else clause handles the unmatched value.

  ## Catch Clause - Local Effect Interception

  The `catch` clause enables local interception of effects using tagged patterns
  `{Module, pattern}`. This provides a unified syntax for handling any effect
  that supports interception.

  ### Catching Throw (Error Handling)

      comp do
        x <- State.get()
        _ <- if x < 0, do: Throw.throw(:negative), else: Comp.pure(:ok)
        return(x * 2)
      catch
        {Throw, :negative} -> return(0)
        {Throw, other} -> return({:error, other})
      end

  When an error is thrown, it's matched against the `{Throw, pattern}` clauses.
  If no pattern matches, the error is re-thrown by default.

  ### Catching Yield (Local Yield Interception)

      comp do
        config <- Yield.yield(:need_config)
        return({:got, config})
      catch
        {Yield, :need_config} -> return(%{timeout: 5000})
        {Yield, other} -> Yield.yield(other)  # re-yield unhandled
      end

  When a yield occurs, it's matched against `{Yield, pattern}` clauses.
  The handler returns a computation that produces the resume input.
  If no pattern matches, the value is re-yielded by default.

  ### Mixed Effect Interception

  Multiple effects can be caught in the same block:

      comp do
        config <- Yield.yield(:get_config)
        result <- risky_operation(config)
        result
      catch
        {Yield, :get_config} -> return(%{default: true})
        {Throw, :timeout} -> return(:retry_later)
        {Throw, err} -> Throw.throw({:wrapped, err})
      end

  ### Handler Installation (Bare Module Patterns)

  In addition to interception with `{Module, pattern}`, the `catch` clause supports
  **handler installation** using bare module patterns:

      comp do
        x <- State.get()
        config <- Reader.ask()
        {x, config}
      catch
        State -> 0                    # Install State handler with initial value 0
        Reader -> %{timeout: 5000}    # Install Reader handler with config value
      end

  Syntax distinction:
  - `{Module, pattern} -> body` = **interception** (calls `Module.intercept/2`)
  - `Module -> config` = **installation** (calls `Module.__handle__/2`)

  Mixed interception and installation work together:

      comp do
        result <- risky_operation()
        result
      catch
        {Throw, :recoverable} -> {:ok, :fallback}  # Interception
        State -> 0                                   # Installation
        Throw -> nil                                 # Installation (no config needed)
      end

  Supported effects: All built-in effects implement `__handle__/2`. See each
  effect's module documentation for the config format it accepts.

  ### Composition Order

  Consecutive same-module clauses are grouped into one handler. Each time the
  module changes, a new interceptor layer is added. First group is innermost:

      catch
        {Throw, :a} -> ...   # ─┐ group 1 (inner)
        {Throw, :b} -> ...   # ─┘
        {Yield, :x} -> ...   # ─── group 2 (middle)
        {Throw, :c} -> ...   # ─── group 3 (outer)

  This gives you full control - a throw from the Yield handler (group 2)
  would be caught by group 3, not group 1.

  ## Combined Else and Catch

  Both clauses can be used together. The `else` must come before `catch`:

      comp do
        {:ok, x} <- might_fail_match()
        _ <- might_throw_error(x)
        return(x)
      else
        {:error, reason} -> return({:match_failed, reason})
      catch
        {Throw, :some_error} -> return(:caught_throw)
      end

  Semantic ordering: `catch(else(body))`. This means:
  - `else` handles pattern match failures from the main computation
  - `catch` handles throws from both the main computation AND the else handler

  ## Extending Catch to Custom Effects

  Effects can support `catch` interception by implementing the optional
  `intercept/2` callback in `Skuld.Comp.IHandler`:

      @impl Skuld.Comp.IHandler
      def intercept(comp, handler_fn) do
        # Wrap comp, intercepting effect operations
        # handler_fn receives intercepted value, returns computation
      end

  See `Skuld.Effects.Throw.catch_error/2` and `Skuld.Effects.Yield.respond/2`
  for implementation examples.

  ## Installing Handlers

  Use the pipe operator with `Module.with_handler/2` to install scoped handlers:

      comp do
        x <- State.get()
        y <- Reader.ask()
        return(x + y)
      end
      |> State.with_handler(0)
      |> Reader.with_handler(:config)

  Handlers are applied in order (first in pipe = innermost).

  ## Function Definitions

      defcomp increment() do
        x <- State.get()
        _ <- State.put(x + 1)
        return(x + 1)
      end

      defcompp private_helper() do
        ctx <- Reader.ask()
        return(ctx.value)
      end

  Function definitions also support else and catch:

      defcomp safe_get() do
        {:ok, x} <- fetch_value()
        return(x)
      else
        {:error, _} -> return(:default)
      catch
        {Throw, :serious_error} -> return(:fallback)
      end
  """

  @doc """
  Define a public function whose body is a `comp` block.

  Supports optional `else` and `catch` clauses.

  ## Example

      defcomp fetch_and_increment() do
        x <- State.get()
        _ <- State.put(x + 1)
        return(x)
      end

      defcomp safe_fetch() do
        {:ok, x} <- dangerous_op()
        return(x)
      else
        {:error, _} -> return(:default)
      catch
        {Throw, :error} -> return(:fallback)
      end
  """
  defmacro defcomp(call_ast, clauses) do
    Skuld.Comp.CompBlock.Impl.defcomp(__CALLER__, call_ast, clauses)
  end

  @doc """
  Define a private function whose body is a `comp` block.

  Supports optional `else` and `catch` clauses.

  ## Example

      defcompp internal_helper() do
        x <- Reader.ask()
        return(x.config)
      end
  """
  defmacro defcompp(call_ast, clauses) do
    Skuld.Comp.CompBlock.Impl.defcompp(__CALLER__, call_ast, clauses)
  end

  @doc """
  Create a computation using do-notation style syntax.

  Transforms arrow bindings (`<-`) into `Skuld.Comp.bind` chains.
  Regular assignments (`=`) are preserved as-is.

  Supports optional `else` and `catch` clauses.

  ## Example

      comp do
        x <- State.get()
        y = x * 2
        _ <- State.put(y)
        return(y)
      end

  With else and catch clauses:

      comp do
        {:ok, x} <- risky_operation()
        return(x)
      else
        {:error, reason} -> return({:failed, reason})
      catch
        {Throw, :error} -> return(:default)
      end
  """
  defmacro comp(clauses) do
    Skuld.Comp.CompBlock.Impl.comp(__CALLER__, clauses)
  end

  defmodule Impl do
    @moduledoc false

    def defcomp(caller, call_ast, clauses) do
      validate_clauses!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      else_block = Keyword.get(clauses, :else)
      catch_block = Keyword.get(clauses, :catch)

      quote do
        def unquote(call_ast) do
          Skuld.Comp.CompBlock.comp(unquote(build_clauses(do_block, else_block, catch_block)))
        end
      end
    end

    def defcompp(caller, call_ast, clauses) do
      validate_clauses!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      else_block = Keyword.get(clauses, :else)
      catch_block = Keyword.get(clauses, :catch)

      quote do
        defp unquote(call_ast) do
          Skuld.Comp.CompBlock.comp(unquote(build_clauses(do_block, else_block, catch_block)))
        end
      end
    end

    defp build_clauses(do_block, else_block, catch_block) do
      # Build clauses in correct order: do, else, catch
      # Using list concatenation to preserve order (Keyword.put prepends)
      [{:do, do_block}]
      |> maybe_append_clause(:else, else_block)
      |> maybe_append_clause(:catch, catch_block)
    end

    defp maybe_append_clause(clauses, _key, nil), do: clauses
    defp maybe_append_clause(clauses, key, value), do: clauses ++ [{key, value}]

    def comp(caller, clauses) do
      validate_clauses!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      else_block = Keyword.get(clauses, :else)
      catch_block = Keyword.get(clauses, :catch)

      # Rewrite the do block, generating multi-clause continuations if else is present
      has_else = else_block != nil
      rewritten_do = rewrite_block(caller, do_block, has_else)

      # Wrap with else if present (innermost)
      with_else =
        if else_block do
          wrap_with_else(rewritten_do, else_block)
        else
          rewritten_do
        end

      # Wrap with catch if present (outermost)
      result =
        if catch_block do
          wrap_with_catch(caller, with_else, catch_block)
        else
          with_else
        end

      quote do
        import Skuld.Comp.BaseOps
        unquote(result)
      end
    end

    # Validate that only supported clauses are present and in correct order
    defp validate_clauses!(caller, clauses) do
      keys = Keyword.keys(clauses)
      invalid = keys -- [:do, :else, :catch]

      if invalid != [] do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "invalid clauses in comp block: #{inspect(invalid)}. " <>
              "Only :do, :else, and :catch are supported."
      end

      unless Keyword.has_key?(clauses, :do) do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "comp block requires a :do clause"
      end

      # Validate ordering: else must come before catch
      catch_index = Enum.find_index(keys, &(&1 == :catch))
      else_index = Enum.find_index(keys, &(&1 == :else))

      if catch_index && else_index && catch_index < else_index do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "in comp block, `else` must come before `catch` " <>
              "(else handles pattern match failures, catch handles thrown errors and wraps else)"
      end
    end

    # Wrap the body computation in Throw.catch_error for else handling
    defp wrap_with_else(body, else_block) do
      else_handler_fn = build_else_handler_fn(else_block)

      quote do
        Skuld.Effects.Throw.catch_error(
          unquote(body),
          unquote(else_handler_fn)
        )
      end
    end

    # Wrap the body computation with effect interceptors based on catch clauses.
    # Catch clauses use tagged patterns: {Module, pattern} -> body
    # Consecutive same-module clauses are grouped into one handler.
    # Clause order determines composition order (first group innermost).
    defp wrap_with_catch(caller, body, catch_block) do
      clauses = extract_clauses(catch_block)

      # Parse and chunk consecutive clauses by effect module
      chunks = chunk_consecutive_catch_clauses(caller, clauses)

      # Compose interceptors in chunk order (first chunk innermost)
      compose_catch_interceptors(body, chunks)
    end

    # Parse a catch clause - either:
    # - {Module, pattern} -> body  (interception)
    # - Module -> config           (handler installation)
    #
    # Returns {:intercept, module_ast, pattern, meta, body}
    #      or {:install, module_ast, config, meta}
    # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
    defp parse_tagged_catch_clause(caller, {:->, meta, [[pattern], body]}) do
      case pattern do
        # Tuple pattern: {Module, inner_pattern} -> body  (interception)
        {module_ast, inner_pattern} when not is_nil(module_ast) ->
          {:intercept, module_ast, inner_pattern, meta, body}

        # Bare module: Module -> config  (installation)
        {:__aliases__, _, _} = module_ast ->
          {:install, module_ast, body, meta}

        # Bare atom module (e.g., Elixir.Foo)
        module_ast when is_atom(module_ast) ->
          {:install, module_ast, body, meta}

        _ ->
          line = Keyword.get(meta, :line) || (caller && caller.line) || 0
          file = (caller && caller.file) || "nofile"

          raise CompileError,
            file: file,
            line: line,
            description:
              "invalid catch clause pattern: expected {Module, pattern} or Module, got: #{Macro.to_string(pattern)}"
      end
    end

    # Chunk consecutive catch clauses by their effect module AND type
    # We normalize the module AST for comparison since different occurrences
    # have different metadata (line numbers, counters)
    # Returns a list of {:intercept | :install, original_module_ast, clauses} tuples
    defp chunk_consecutive_catch_clauses(caller, clauses) do
      clauses
      |> Enum.map(&parse_tagged_catch_clause(caller, &1))
      |> Enum.chunk_by(fn parsed ->
        # Group by (type, normalized_module)
        case parsed do
          {:intercept, module_ast, _pattern, _meta, _body} ->
            {:intercept, normalize_module_ast(module_ast)}

          {:install, module_ast, _config, _meta} ->
            {:install, normalize_module_ast(module_ast)}
        end
      end)
      |> Enum.map(fn chunk ->
        # Get the type and original module AST from the first clause
        case hd(chunk) do
          {:intercept, original_module_ast, _, _, _} ->
            {:intercept, original_module_ast, chunk}

          {:install, original_module_ast, _, _} ->
            {:install, original_module_ast, chunk}
        end
      end)
    end

    # Normalize module AST for grouping - strip metadata
    defp normalize_module_ast({:__aliases__, _meta, parts}), do: {:__aliases__, [], parts}
    defp normalize_module_ast(other), do: other

    # Compose interceptors/installations around the body in chunk order (first chunk innermost)
    defp compose_catch_interceptors(body, chunks) do
      Enum.reduce(chunks, body, fn
        {:intercept, module_ast, module_clauses}, acc ->
          handler_fn = build_intercept_handler_fn(module_ast, module_clauses)

          quote do
            unquote(module_ast).intercept(unquote(acc), unquote(handler_fn))
          end

        {:install, module_ast, module_clauses}, acc ->
          # For install, there should be exactly one clause with the config
          # (consecutive same-module installs are grouped, but each is independent)
          # We chain them: Module.__handle__(Module.__handle__(acc, config1), config2)
          Enum.reduce(module_clauses, acc, fn {:install, _mod, config, _meta}, inner_acc ->
            quote do
              unquote(module_ast).__handle__(unquote(inner_acc), unquote(config))
            end
          end)
      end)
    end

    # Check if module AST refers to Throw (used for default re-dispatch)
    defp module_is_throw?({:__aliases__, _, [:Throw]}), do: true
    defp module_is_throw?({:__aliases__, _, [Skuld, Effects, Throw]}), do: true
    defp module_is_throw?(Skuld.Effects.Throw), do: true
    defp module_is_throw?(_), do: false

    # Build handler function for interception clauses
    defp build_intercept_handler_fn(module_ast, module_clauses) do
      # Build case clauses from the module's patterns
      case_clauses =
        Enum.map(module_clauses, fn {:intercept, _module, pattern, meta, body} ->
          rewritten_body = rewrite_block(nil, body, false)
          {:->, meta, [[pattern], rewritten_body]}
        end)

      # Add default re-dispatch clause if no catch-all
      final_clauses =
        if has_catch_all_clause_for_patterns?(module_clauses) do
          case_clauses
        else
          case_clauses ++ [default_redispatch_clause(module_ast)]
        end

      # Build: fn value -> import BaseOps; case value do ... end end
      quote do
        fn __skuld_caught_value__ ->
          import Skuld.Comp.BaseOps

          case __skuld_caught_value__ do
            unquote(final_clauses)
          end
        end
      end
    end

    # Check if any clause has a catch-all pattern (variable or _)
    defp has_catch_all_clause_for_patterns?(module_clauses) do
      Enum.any?(module_clauses, fn {:intercept, _module, pattern, _meta, _body} ->
        catch_all_pattern?(pattern)
      end)
    end

    # Check if a pattern is a catch-all (variable or underscore)
    defp catch_all_pattern?({var, _, context})
         when is_atom(var) and is_atom(context) and var != :^ do
      true
    end

    defp catch_all_pattern?({:_, _, _}), do: true
    defp catch_all_pattern?(_), do: false

    # Build default re-dispatch clause for unhandled values
    # Throw: re-throw, Yield: re-yield
    defp default_redispatch_clause(module_ast) do
      redispatch_call =
        cond do
          module_is_throw?(module_ast) ->
            quote do: Skuld.Effects.Throw.throw(__skuld_unhandled__)

          module_is_yield?(module_ast) ->
            quote do: Skuld.Effects.Yield.yield(__skuld_unhandled__)

          true ->
            # For unknown effects, raise a helpful error at runtime
            # Users should provide catch-all patterns for custom effects
            quote do
              raise ArgumentError,
                    "unhandled catch value for #{inspect(unquote(module_ast))}: #{inspect(__skuld_unhandled__)}"
            end
        end

      {:->, [], [[quote(do: __skuld_unhandled__)], redispatch_call]}
    end

    # Check if module AST refers to Yield
    defp module_is_yield?({:__aliases__, _, [:Yield]}), do: true
    defp module_is_yield?({:__aliases__, _, [Skuld, Effects, Yield]}), do: true
    defp module_is_yield?(Skuld.Effects.Yield), do: true
    defp module_is_yield?(_), do: false

    # Build the else handler function
    # Catches MatchFailed, re-throws other errors
    defp build_else_handler_fn(else_block) do
      clauses = extract_clauses(else_block)

      # Rewrite clause bodies
      rewritten_clauses =
        Enum.map(clauses, fn {:->, meta, [patterns, body]} ->
          rewritten_body = rewrite_block(nil, body, false)
          {:->, meta, [patterns, rewritten_body]}
        end)

      # Add default re-throw clause if no catch-all
      final_clauses =
        if has_catch_all_clause?(clauses) do
          rewritten_clauses
        else
          default_clause =
            {:->, [],
             [
               [quote(do: __skuld_unhandled_match__)],
               quote(
                 do:
                   Skuld.Effects.Throw.throw(%Skuld.Comp.MatchFailed{
                     value: __skuld_unhandled_match__
                   })
               )
             ]}

          rewritten_clauses ++ [default_clause]
        end

      # Build the function that catches MatchFailed, re-throws others
      quote do
        fn
          %Skuld.Comp.MatchFailed{value: __skuld_match_value__} ->
            import Skuld.Comp.BaseOps

            case __skuld_match_value__ do
              unquote(final_clauses)
            end

          __skuld_other_error__ ->
            Skuld.Effects.Throw.throw(__skuld_other_error__)
        end
      end
    end

    # Extract clauses from a block
    defp extract_clauses({:->, _, _} = single_clause), do: [single_clause]
    defp extract_clauses({:__block__, _, clauses}), do: clauses
    defp extract_clauses(clauses) when is_list(clauses), do: clauses
    defp extract_clauses(nil), do: []

    # Check if there's a catch-all clause (variable pattern or _)
    defp has_catch_all_clause?(clauses) do
      Enum.any?(clauses, fn
        {:->, _, [[{var, _, context}], _body]}
        when is_atom(var) and is_atom(context) and var != :^ ->
          # Variable pattern (but not pinned)
          true

        {:->, _, [[{:_, _, _}], _body]} ->
          # Underscore pattern
          true

        _ ->
          false
      end)
    end

    # Check if a pattern is "complex" (might fail to match)
    # Simple patterns: variables, underscore
    # Complex patterns: tuples, lists, maps, structs, literals, pins
    defp complex_pattern?({name, _meta, context})
         when is_atom(name) and is_atom(context) and name != :^ do
      # Simple variable (including underscore variants like _foo)
      false
    end

    defp complex_pattern?({:_, _meta, _context}) do
      # Underscore
      false
    end

    defp complex_pattern?(_) do
      # Everything else: tuples, lists, maps, structs, literals, pins, etc.
      true
    end

    # Rewrite block expressions
    # caller: the __CALLER__ context for error reporting (may be nil for nested blocks)
    # has_else: whether to generate multi-clause continuations for complex patterns
    # is_first: whether this is the first expression (needs exception wrapping)
    #
    # Only the FIRST expression needs explicit exception wrapping because:
    # - Subsequent expressions are inside bind's continuation, which already has try/catch
    # - The first expression is evaluated before any computation context exists
    defp rewrite_block(caller, block, has_else)

    defp rewrite_block(caller, {:__block__, _, exprs}, has_else),
      do: rewrite_exprs(caller, exprs, has_else, _is_first = true)

    defp rewrite_block(caller, expr, has_else),
      do: rewrite_exprs(caller, [expr], has_else, _is_first = true)

    # Single/last expression - this is always allowed (auto-lifted to pure)
    defp rewrite_exprs(_caller, [last], _has_else, is_first) do
      if is_first do
        # First expression needs wrapping - evaluated before computation context exists
        Skuld.Comp.ConvertThrow.wrap_expr(last)
      else
        # Inside a bind continuation - already protected by bind's try/catch
        last
      end
    end

    # = assignment - allowed in any position
    defp rewrite_exprs(caller, [{:=, meta, [lhs, rhs]} | rest], has_else, is_first) do
      # Note: = assignments don't create computation context, so if the first
      # expression is an assignment, the RHS still executes outside any try/catch.
      # We wrap the entire rest (which includes the assignment) when is_first.
      rest_rewritten = rewrite_exprs(caller, rest, has_else, _is_first = false)

      base_expr =
        if has_else and complex_pattern?(lhs) do
          # Wrap in case with fallback for match failure
          quote do
            case unquote(rhs) do
              unquote(lhs) ->
                unquote(rest_rewritten)

              __skuld_nomatch__ ->
                Skuld.Effects.Throw.throw(%Skuld.Comp.MatchFailed{value: __skuld_nomatch__})
            end
          end
        else
          # Simple pattern or no else - regular assignment
          quote do
            unquote({:=, meta, [lhs, rhs]})
            unquote(rest_rewritten)
          end
        end

      if is_first do
        # Wrap the entire assignment + rest to catch exceptions in RHS
        Skuld.Comp.ConvertThrow.wrap_expr(base_expr)
      else
        base_expr
      end
    end

    # <- binding - allowed in any position
    defp rewrite_exprs(caller, [{:<-, _meta, [lhs, rhs]} | rest], has_else, is_first) do
      rest_rewritten = rewrite_exprs(caller, rest, has_else, _is_first = false)

      # Only wrap RHS if this is the first expression
      rhs_expr = if is_first, do: Skuld.Comp.ConvertThrow.wrap_expr(rhs), else: rhs

      if has_else and complex_pattern?(lhs) do
        # Generate multi-clause bind with match failure throw
        binder_with_else(lhs, rhs_expr, rest_rewritten)
      else
        # Simple pattern or no else - regular bind
        binder(lhs, rhs_expr, rest_rewritten)
      end
    end

    # Bare expression followed by more - NOT allowed, raise compile error
    defp rewrite_exprs(caller, [expr | _rest], _has_else, _is_first) do
      {line, description} = bare_expression_error_info(caller, expr)

      raise CompileError,
        file: (caller && caller.file) || "nofile",
        line: line,
        description: description
    end

    # Get line number and description for bare expression error
    defp bare_expression_error_info(caller, expr) do
      # Try to extract line number from the expression's metadata
      line =
        case expr do
          {_op, meta, _args} when is_list(meta) -> Keyword.get(meta, :line)
          _ -> nil
        end

      # Fall back to caller's line if expression doesn't have line info
      line = line || (caller && caller.line) || 0

      expr_preview =
        expr
        |> Macro.to_string()
        |> String.slice(0, 50)

      description =
        "bare expression in comp block: `#{expr_preview}`. " <>
          "Only `pattern <- computation` (effectful bind), " <>
          "`pattern = expression` (pure bind), or a final expression are allowed. " <>
          "If you want to execute a side effect, use `_ = expression` or `_ <- computation`."

      {line, description}
    end

    defp binder(lhs, rhs, body) do
      quote do
        Skuld.Comp.bind(unquote(rhs), fn unquote(lhs) -> unquote(body) end)
      end
    end

    # Generate bind with multi-clause continuation for else support
    defp binder_with_else(lhs, rhs, body) do
      quote do
        Skuld.Comp.bind(unquote(rhs), fn
          unquote(lhs) ->
            unquote(body)

          __skuld_nomatch__ ->
            Skuld.Effects.Throw.throw(%Skuld.Comp.MatchFailed{value: __skuld_nomatch__})
        end)
      end
    end
  end
end
