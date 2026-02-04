# Macro for defining serializable operation structs.
#
# Defines a struct module with Jason.Encoder implementation for
# JSON serialization via `Skuld.Comp.SerializableStruct`.
#
# ## Example
#
#     defmodule Skuld.Effects.State do
#       import Skuld.Comp.DefOp
#
#       def_op Get
#       def_op Put, [:value]
#
#       # Creates:
#       # - Skuld.Effects.State.Get with defstruct []
#       # - Skuld.Effects.State.Put with defstruct [:value]
#       # - Jason.Encoder implementations for both
#     end
#
# The structs can then be used as effect arguments:
#
#     def get, do: Skuld.Comp.effect(@sig, %Get{})
#     def put(value), do: Skuld.Comp.effect(@sig, %Put{value: value})
#
# And serialized to JSON:
#
#     Jason.encode!(%State.Put{value: 42})
#     # => {"__struct__":"Elixir.Skuld.Effects.State.Put","value":42}
#
# ## Atom Fields
#
# Some fields may contain atoms (like tags) that need to be converted back
# from strings during JSON deserialization. Use the `atom_fields` option:
#
#     def_op Get, [:tag], atom_fields: [:tag]
#
# This generates a `from_json/1` callback that converts the specified fields
# from strings to existing atoms.
defmodule Skuld.Comp.DefOp do
  @moduledoc false

  @doc """
  Define an operation struct with JSON serialization.

  ## Arguments

  - `mod` - the module name (will be nested under the calling module)
  - `fields` - list of struct fields (default: [])
  - `opts` - keyword options:
    - `atom_fields` - list of fields that should be converted from strings to atoms
      during deserialization
  """
  defmacro def_op(mod, fields \\ [], opts \\ []) do
    atom_fields = Keyword.get(opts, :atom_fields, [])
    from_json_fn = build_from_json_fn(fields, atom_fields)

    quote do
      defmodule unquote(mod) do
        @moduledoc false
        defstruct unquote(fields)
        unquote(from_json_fn)
      end

      defimpl Jason.Encoder, for: unquote(mod) do
        def encode(value, opts) do
          value
          |> Skuld.Comp.SerializableStruct.encode()
          |> Jason.Encode.map(opts)
        end
      end
    end
  end

  @doc false
  def build_from_json_fn(_fields, []), do: nil

  def build_from_json_fn(fields, atom_fields) do
    quote do
      def from_json(map) do
        attrs =
          Enum.reduce(unquote(fields), %{}, fn field, acc ->
            key = Atom.to_string(field)

            value =
              case Map.fetch(map, key) do
                {:ok, v} -> v
                :error -> Map.get(map, field)
              end

            converted =
              if field in unquote(atom_fields) do
                case value do
                  s when is_binary(s) -> String.to_existing_atom(s)
                  a when is_atom(a) -> a
                  nil -> nil
                end
              else
                value
              end

            Map.put(acc, field, converted)
          end)

        struct(__MODULE__, attrs)
      end
    end
  end
end
