defmodule Skuld.Credo.CompPureRedundant do
  @moduledoc """
  Credo check that detects redundant `Comp.pure` and `Comp.return` calls.

  `Comp.pure/1` and `Comp.return/1` are almost never necessary — bare values
  are automatically lifted by `Comp.call/3`. This check flags
  `Comp.pure(arg)` and `Comp.return(arg)` where the argument is a literal
  value, a variable reference, or a simple expression that would be trivially
  auto-lifted.

  It does NOT flag cases where the argument is a function call or other
  non-trivial AST node, since those may be legitimate computation-construction
  patterns (e.g. `Comp.pure(fn a, b -> ... end)` to return a function/2).
  """

  use Credo.Check, category: :refactor

  alias Credo.Code
  alias Credo.IssueMeta

  @explanation [
    check: @moduledoc,
    params: []
  ]

  @doc "Called by Credo to check source files"
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    issues =
      source_file
      |> Code.ast()
      |> collect_issues(issue_meta)
      |> Enum.reverse()

    issues
  end

  defp collect_issues(ast, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, check_node(node, acc, issue_meta)}
      end)

    issues
  end

  # Comp.pure(literal) or Comp.pure(variable) or Comp.pure(simple_expr)
  defp check_node(
         {{:., _, [{:__aliases__, _, [:Comp]}, :pure]}, call_meta, [arg]},
         acc,
         issue_meta
       ) do
    if trivial_arg?(arg) do
      issue = format_trivial_issue("Comp.pure", call_meta, issue_meta)
      [issue | acc]
    else
      acc
    end
  end

  # Comp.return(literal) or Comp.return(variable) or Comp.return(simple_expr)
  defp check_node(
         {{:., _, [{:__aliases__, _, [:Comp]}, :return]}, call_meta, [arg]},
         acc,
         issue_meta
       ) do
    if trivial_arg?(arg) do
      issue = format_trivial_issue("Comp.return", call_meta, issue_meta)
      [issue | acc]
    else
      acc
    end
  end

  defp check_node(_node, acc, _issue_meta), do: acc

  defp format_trivial_issue(name, call_meta, issue_meta) do
    line_no = call_meta[:line] || 1

    format_issue(issue_meta,
      message: "`#{name}` is unnecessary — bare values are auto-lifted by `call/3`",
      trigger: name,
      line_no: line_no
    )
  end

  # Literals: atoms, numbers, strings, booleans, nil
  defp trivial_arg?(arg) when is_atom(arg), do: true
  defp trivial_arg?(arg) when is_integer(arg), do: true
  defp trivial_arg?(arg) when is_float(arg), do: true
  defp trivial_arg?(arg) when is_binary(arg), do: true

  # Variable references: {:var_name, meta, context}
  defp trivial_arg?({name, _meta, context}) when is_atom(context) and is_atom(name), do: true

  # List literals (including keyword lists) are common literals
  defp trivial_arg?(arg) when is_list(arg), do: true

  # Tuple literals (not function calls)
  defp trivial_arg?({:{}, _meta, _args}), do: true
  defp trivial_arg?(arg) when is_tuple(arg), do: true

  # Map literals: %{...}
  defp trivial_arg?({:%{}, _meta, _args}), do: true

  # Everything else (function calls, anonymous fns, blocks, etc.) is NOT trivial
  defp trivial_arg?(_arg), do: false
end
