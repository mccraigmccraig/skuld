defmodule Skuld.Credo.CompPureRedundant do
  @moduledoc """
  Credo check that detects redundant `Comp.pure` calls.

  `Comp.pure/1` is almost never necessary — bare values are automatically
  lifted by `Comp.call/3`. This check flags `Comp.pure(arg)` where the
  argument is a literal value, a variable reference, or a simple expression
  that would be trivially auto-lifted.

  It does NOT flag cases where `Comp.pure` wraps function calls or other
  non-trivial AST nodes, since those may be legitimate computation-construction
  patterns.
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
      line_no = call_meta[:line] || 1

      issue =
        format_issue(issue_meta,
          message: "`Comp.pure` is unnecessary — bare values are auto-lifted by `call/3`",
          trigger: "Comp.pure",
          line_no: line_no
        )

      [issue | acc]
    else
      acc
    end
  end

  defp check_node(_node, acc, _issue_meta), do: acc

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
