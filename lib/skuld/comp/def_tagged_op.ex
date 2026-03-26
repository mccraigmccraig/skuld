# Macro for defining tagged-tuple operation types.
#
# Alternative to `def_op` that uses tagged tuples instead of structs
# for operation arguments, trading JSON serialization support for
# lower allocation cost on the hot path.
#
# ## Example
#
#     defmodule Skuld.Effects.State do
#       import Skuld.Comp.DefTaggedOp
#
#       def_tagged_op Get, [:tag]
#       def_tagged_op Put, [:tag, :value]
#
#       # Creates:
#       # - Skuld.Effects.State.Get module with new/1 constructor
#       # - Skuld.Effects.State.Put module with new/2 constructor
#       #
#       # Tagged tuple representation:
#       # - {Skuld.Effects.State.Get, tag}
#       # - {Skuld.Effects.State.Put, tag, value}
#     end
#
# The tagged tuples can then be used as effect arguments:
#
#     def get(tag), do: Skuld.Comp.effect(@sig, {Get, tag})
#     def put(tag, value), do: Skuld.Comp.effect(@sig, {Put, tag, value})
#
# And pattern matched in handlers:
#
#     def handle({Get, tag}, env, k) -> ...
#     def handle({Put, tag, value}, env, k) -> ...
#
# ## Why tagged tuples?
#
# A 2-tuple costs 3 heap words vs a struct/map which requires header +
# __struct__ key + field keys + values. Pattern matching is a direct
# element comparison vs map key lookup.
#
# ## JSON serialization
#
# Not yet supported — this macro is for benchmarking the performance
# impact of the struct-to-tuple migration. JSON serialization support
# will be added if the performance gains justify the migration.
defmodule Skuld.Comp.DefTaggedOp do
  @moduledoc false

  @doc """
  Define a tagged-tuple operation type.

  ## Arguments

  - `mod` - the module name (will be nested under the calling module)
  - `fields` - list of fields (default: [])

  ## Generated code

  Creates a module with:
  - A `new/N` function that constructs the tagged tuple
  - A `tag/0` function that returns the module atom (for pattern matching)

  The tagged tuple format is `{Module, field1, field2, ...}` where
  `Module` is the fully-qualified module atom.
  """
  defmacro def_tagged_op(mod, fields \\ []) do
    field_count = length(fields)

    # Generate new/N function args as vars
    new_args =
      Enum.map(fields, fn field ->
        Macro.var(field, nil)
      end)

    # Generate the tuple construction: {__MODULE__, arg1, arg2, ...}
    tuple_elements =
      [quote(do: __MODULE__) | new_args]

    tuple_expr = {:{}, [], tuple_elements}

    quote do
      defmodule unquote(mod) do
        @moduledoc false

        @doc """
        Construct a tagged tuple for this operation.

        Returns `{#{inspect(__MODULE__)}.#{unquote(mod)}, #{unquote(fields) |> Enum.join(", ")}}`.
        """
        def new(unquote_splicing(new_args)) do
          unquote(tuple_expr)
        end

        @doc "Returns the tag atom for this operation (the module itself)."
        def tag, do: __MODULE__

        @doc "Returns the number of fields (excluding the tag)."
        def field_count, do: unquote(field_count)
      end
    end
  end
end
