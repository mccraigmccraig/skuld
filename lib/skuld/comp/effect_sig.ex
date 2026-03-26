# Shared sig/0 and sig/1 generation for effect modules.
#
# Both `DefSimpleOp` and `DefTaggedOp` inject the same sig functions
# via their `__using__` callback. This module provides the generation
# logic so it's defined once.
#
# ## Generated functions
#
#     sig()          => __MODULE__
#     sig(__MODULE__) => __MODULE__
#     sig(:counter)   => Module.concat(__MODULE__, :Counter)  # camelized
#
# sig/0 is the untagged identity. sig/1 maps tags to per-tag
# module-atom sigs, with an identity shortcut for the default tag.
defmodule Skuld.Comp.EffectSig do
  @moduledoc false

  @doc """
  Returns quoted code that defines sig/0 and sig/1 in the caller module.

  Called once from `__using__` in DefSimpleOp / DefTaggedOp, so no
  guard against redefinition is needed.
  """
  def generate do
    tag_var = Macro.var(:tag, nil)

    quote do
      @__sig__ __MODULE__

      @doc false
      def sig, do: __MODULE__

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
  end
end
