# Macro for defining simple (untagged) effect constructor functions.
#
# Generates a public function that constructs a `Comp.effect/2` call
# with compact atom/tuple operation representations instead of structs.
#
# ## Example
#
#     defmodule Skuld.Effects.Random do
#       import Skuld.Comp.DefSimpleOp
#
#       def_simple_op random_float()
#       def_simple_op random_int(min, max)
#       def_simple_op shuffle(list)
#
#       # Generates (approximately):
#       #
#       #   def random_float do
#       #     Comp.effect(Skuld.Effects.Random, Skuld.Effects.Random.RandomFloat)
#       #   end
#       #
#       #   def random_int(min, max) do
#       #     Comp.effect(Skuld.Effects.Random, {Skuld.Effects.Random.RandomInt, min, max})
#       #   end
#     end
#
# The sig is always `__MODULE__` (the enclosing effect module).
# The operation atom is derived from the function name converted to
# CamelCase and nested under the enclosing module. The operation atom
# is computed at compile time via a module attribute.
#
# ## Operation Representation
#
# - 0-arg ops: bare atom `Module.Op`
# - N-arg ops: tagged tuple `{Module.Op, arg1, arg2, ...}`
#
# This eliminates struct allocation on every operation call.
defmodule Skuld.Comp.DefSimpleOp do
  @moduledoc false

  @doc """
  Define a simple (untagged) effect constructor function.

  The macro accepts a function call form: `def_simple_op name(arg1, arg2, ...)`

  Generates a public function that calls `Comp.effect(__MODULE__, op)` where
  `op` is a bare atom for 0-arg ops or a tagged tuple for N-arg ops.

  The operation atom is computed at compile time via a module attribute,
  so there is zero runtime overhead for the atom construction.
  """
  defmacro def_simple_op(call) do
    {fun_name, args} = decompose_call(call)
    op_camel = fun_name_to_op_camel(fun_name)
    op_attr = :"__#{fun_name}_op__"

    arg_vars =
      Enum.map(args, fn {name, _, _} -> Macro.var(name, nil) end)

    effect_call = build_effect_call(op_attr, arg_vars)

    quote do
      Module.put_attribute(
        __MODULE__,
        unquote(op_attr),
        Module.concat(__MODULE__, unquote(op_camel))
      )

      @doc false
      def unquote(fun_name)(unquote_splicing(arg_vars)) do
        unquote(effect_call)
      end
    end
  end

  # Decompose `name(arg1, arg2)` call form into {name, args}
  defp decompose_call({fun_name, _, nil}) when is_atom(fun_name), do: {fun_name, []}
  defp decompose_call({fun_name, _, args}) when is_atom(fun_name), do: {fun_name, args}

  # Convert snake_case function name to CamelCase atom
  # e.g. :random_float -> :RandomFloat, :get -> :Get
  defp fun_name_to_op_camel(fun_name) do
    fun_name
    |> Atom.to_string()
    |> Macro.camelize()
    |> String.to_atom()
  end

  # Build the Comp.effect call with appropriate op representation.
  # References a module attribute (computed at compile time) for the op atom.
  defp build_effect_call(op_attr, []) do
    # 0-arg: bare atom
    op_ref = {:@, [], [{op_attr, [], nil}]}

    quote do
      Skuld.Comp.effect(__MODULE__, unquote(op_ref))
    end
  end

  defp build_effect_call(op_attr, arg_vars) do
    # N-arg: tagged tuple {OpAtom, arg1, arg2, ...}
    op_ref = {:@, [], [{op_attr, [], nil}]}
    tuple_elements = [op_ref | arg_vars]
    tuple_expr = {:{}, [], tuple_elements}

    quote do
      Skuld.Comp.effect(__MODULE__, unquote(tuple_expr))
    end
  end
end
