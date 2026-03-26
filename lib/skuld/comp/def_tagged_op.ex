# Macro for defining tagged effect constructor functions.
#
# Generates a public function that constructs a `Comp.effect/2` call
# with a per-tag module-atom sig and compact atom/tuple operation
# representations instead of structs.
#
# ## Example
#
#     defmodule Skuld.Effects.AtomicState do
#       import Skuld.Comp.DefTaggedOp
#
#       def_tagged_op get()
#       def_tagged_op put(value)
#       def_tagged_op modify(fun)
#
#       # Generates (approximately):
#       #
#       #   def get(tag \\ __MODULE__) do
#       #     Comp.effect(sig(tag), Skuld.Effects.AtomicState.Get)
#       #   end
#       #
#       #   def put(tag \\ __MODULE__, value) do
#       #     Comp.effect(sig(tag), {Skuld.Effects.AtomicState.Put, value})
#       #   end
#       #
#       # where sig(tag) returns __MODULE__ when tag == __MODULE__,
#       # or Module.concat(__MODULE__, tag) otherwise.
#     end
#
# The first argument is always `tag` with default `__MODULE__`.
# The sig is an atom: `__MODULE__` for the default tag, or
# `Module.concat(__MODULE__, tag)` for explicit tags.
#
# ## Operation Representation
#
# - 0-arg ops (after tag): bare atom `Module.Op`
# - N-arg ops (after tag): tagged tuple `{Module.Op, arg1, arg2, ...}`
#
# ## Sig Computation
#
# Per-tag module-atom sigs give O(1) atom-keyed map lookup in the
# evidence map, cheaper than tuple-keyed lookups.
defmodule Skuld.Comp.DefTaggedOp do
  @moduledoc false

  @doc """
  Define a tagged effect constructor function.

  The macro accepts a function call form: `def_tagged_op name(arg1, arg2, ...)`

  Generates a public function with a prepended `tag` argument (default
  `__MODULE__`) that calls `Comp.effect(sig(tag), op)` where `op` is a
  bare atom for 0-arg ops or a tagged tuple for N-arg ops.

  Also generates a `sig/1` helper (guarded to avoid redefinition) that
  maps tags to per-tag module-atom sigs.

  The operation atom is computed at compile time via a module attribute.
  """
  defmacro def_tagged_op(call) do
    {fun_name, args} = decompose_call(call)
    op_camel = fun_name_to_op_camel(fun_name)
    op_attr = :"__#{fun_name}_op__"

    arg_vars =
      Enum.map(args, fn {name, _, _} -> Macro.var(name, nil) end)

    effect_call = build_effect_call(op_attr, arg_vars)
    tag_var = Macro.var(:tag, nil)

    quote do
      # Generate sig/1 helper once per module
      unless Module.get_attribute(__MODULE__, :__tagged_op_sig_defined__) do
        Module.put_attribute(__MODULE__, :__tagged_op_sig_defined__, true)

        @doc false
        def sig(unquote(tag_var)) when unquote(tag_var) == __MODULE__, do: __MODULE__

        def sig(unquote(tag_var)) do
          camelized =
            unquote(tag_var)
            |> Atom.to_string()
            |> Macro.camelize()
            |> String.to_atom()

          Module.concat(__MODULE__, camelized)
        end
      end

      Module.put_attribute(
        __MODULE__,
        unquote(op_attr),
        Module.concat(__MODULE__, unquote(op_camel))
      )

      @doc false
      def unquote(fun_name)(unquote(tag_var) \\ __MODULE__, unquote_splicing(arg_vars)) do
        unquote(effect_call)
      end
    end
  end

  # Decompose `name(arg1, arg2)` call form into {name, args}
  defp decompose_call({fun_name, _, nil}) when is_atom(fun_name), do: {fun_name, []}
  defp decompose_call({fun_name, _, args}) when is_atom(fun_name), do: {fun_name, args}

  # Convert snake_case function name to CamelCase atom
  defp fun_name_to_op_camel(fun_name) do
    fun_name
    |> Atom.to_string()
    |> Macro.camelize()
    |> String.to_atom()
  end

  # Build the Comp.effect call with sig(tag) and appropriate op representation
  defp build_effect_call(op_attr, []) do
    op_ref = {:@, [], [{op_attr, [], nil}]}
    tag_var = Macro.var(:tag, nil)

    quote do
      Skuld.Comp.effect(sig(unquote(tag_var)), unquote(op_ref))
    end
  end

  defp build_effect_call(op_attr, arg_vars) do
    op_ref = {:@, [], [{op_attr, [], nil}]}
    tag_var = Macro.var(:tag, nil)
    tuple_elements = [op_ref | arg_vars]
    tuple_expr = {:{}, [], tuple_elements}

    quote do
      Skuld.Comp.effect(sig(unquote(tag_var)), unquote(tuple_expr))
    end
  end
end
