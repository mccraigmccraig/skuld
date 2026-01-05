defmodule Skuld.Effects.EffectLogger.LogEntry do
  @moduledoc """
  Structs representing different types of effect log entries.

  All entries are JSON-serializable via Jason and can be decoded back
  using `from_json/1` functions on each struct module.

  ## Entry Types

  - `Completed` - Effect completed synchronously with a result
  - `Thrown` - Effect threw an error (terminal)
  - `Started` - Suspending effect began execution
  - `Suspended` - Effect yielded/suspended with a value
  - `Resumed` - Suspended effect was resumed with input
  - `Finished` - Suspending effect completed after resume(s)

  ## Common Fields

  All entries have:
  - `:id` - UUID string identifying the effect invocation
  - `:timestamp` - When this event occurred (DateTime)

  Effect-identifying entries (`Completed`, `Thrown`, `Started`) also have:
  - `:effect` - The effect signature (module atom)
  - `:args` - The effect operation struct

  ## JSON Serialization

  All structs implement the `Jason.Encoder` protocol. Timestamps are
  serialized as ISO8601 strings, and effect modules as strings.

  To decode, use the `from_json/1` function on each struct module:

      json = Jason.encode!(log_entry)
      decoded = Jason.decode!(json)
      entry = Skuld.Comp.SerializableStruct.decode(decoded)
  """

  alias Skuld.Comp.SerializableStruct

  # Helper functions shared by all entry types
  defmodule Helpers do
    @moduledoc false

    def encode_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    def encode_timestamp(other), do: other

    def decode_timestamp(str) when is_binary(str) do
      case DateTime.from_iso8601(str) do
        {:ok, dt, _offset} -> dt
        _ -> str
      end
    end

    def decode_timestamp(other), do: other

    def encode_effect(effect) when is_atom(effect), do: Atom.to_string(effect)
    def encode_effect(other), do: other

    def decode_effect(str) when is_binary(str) do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> str
    end

    def decode_effect(other), do: other

    def encode_args(args) do
      if is_struct(args) do
        SerializableStruct.encode(args)
      else
        args
      end
    end

    def decode_args(args) when is_map(args) do
      SerializableStruct.decode(args)
    end

    def decode_args(other), do: other
  end

  defmodule Completed do
    @moduledoc "Simple effect completed synchronously"
    @enforce_keys [:id, :effect, :args, :result, :timestamp]
    defstruct [:id, :effect, :args, :result, :timestamp]

    @type t :: %__MODULE__{
            id: String.t(),
            effect: atom(),
            args: term(),
            result: term(),
            timestamp: DateTime.t()
          }

    alias Skuld.Effects.EffectLogger.LogEntry.Helpers

    @doc "Decode a JSON-decoded map into a Completed struct"
    def from_json(map) do
      %__MODULE__{
        id: map["id"] || map[:id],
        effect: Helpers.decode_effect(map["effect"] || map[:effect]),
        args: Helpers.decode_args(map["args"] || map[:args]),
        result: map["result"] || map[:result],
        timestamp: Helpers.decode_timestamp(map["timestamp"] || map[:timestamp])
      }
    end

    defimpl Jason.Encoder do
      def encode(entry, opts) do
        map = %{
          "__struct__" => "Elixir.Skuld.Effects.EffectLogger.LogEntry.Completed",
          "id" => entry.id,
          "effect" => Helpers.encode_effect(entry.effect),
          "args" => Helpers.encode_args(entry.args),
          "result" => entry.result,
          "timestamp" => Helpers.encode_timestamp(entry.timestamp)
        }

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule Thrown do
    @moduledoc "Effect threw an error (terminal sentinel)"
    @enforce_keys [:id, :effect, :args, :error, :timestamp]
    defstruct [:id, :effect, :args, :error, :timestamp]

    @type t :: %__MODULE__{
            id: String.t(),
            effect: atom(),
            args: term(),
            error: term(),
            timestamp: DateTime.t()
          }

    alias Skuld.Effects.EffectLogger.LogEntry.Helpers

    @doc "Decode a JSON-decoded map into a Thrown struct"
    def from_json(map) do
      %__MODULE__{
        id: map["id"] || map[:id],
        effect: Helpers.decode_effect(map["effect"] || map[:effect]),
        args: Helpers.decode_args(map["args"] || map[:args]),
        error: map["error"] || map[:error],
        timestamp: Helpers.decode_timestamp(map["timestamp"] || map[:timestamp])
      }
    end

    defimpl Jason.Encoder do
      def encode(entry, opts) do
        map = %{
          "__struct__" => "Elixir.Skuld.Effects.EffectLogger.LogEntry.Thrown",
          "id" => entry.id,
          "effect" => Helpers.encode_effect(entry.effect),
          "args" => Helpers.encode_args(entry.args),
          "error" => entry.error,
          "timestamp" => Helpers.encode_timestamp(entry.timestamp)
        }

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule Started do
    @moduledoc "Suspending effect started execution"
    @enforce_keys [:id, :effect, :args, :timestamp]
    defstruct [:id, :effect, :args, :timestamp]

    @type t :: %__MODULE__{
            id: String.t(),
            effect: atom(),
            args: term(),
            timestamp: DateTime.t()
          }

    alias Skuld.Effects.EffectLogger.LogEntry.Helpers

    @doc "Decode a JSON-decoded map into a Started struct"
    def from_json(map) do
      %__MODULE__{
        id: map["id"] || map[:id],
        effect: Helpers.decode_effect(map["effect"] || map[:effect]),
        args: Helpers.decode_args(map["args"] || map[:args]),
        timestamp: Helpers.decode_timestamp(map["timestamp"] || map[:timestamp])
      }
    end

    defimpl Jason.Encoder do
      def encode(entry, opts) do
        map = %{
          "__struct__" => "Elixir.Skuld.Effects.EffectLogger.LogEntry.Started",
          "id" => entry.id,
          "effect" => Helpers.encode_effect(entry.effect),
          "args" => Helpers.encode_args(entry.args),
          "timestamp" => Helpers.encode_timestamp(entry.timestamp)
        }

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule Suspended do
    @moduledoc "Effect suspended/yielded a value"
    @enforce_keys [:id, :timestamp]
    defstruct [:id, :yielded, :timestamp]

    @type t :: %__MODULE__{
            id: String.t(),
            yielded: term(),
            timestamp: DateTime.t()
          }

    alias Skuld.Effects.EffectLogger.LogEntry.Helpers

    @doc "Decode a JSON-decoded map into a Suspended struct"
    def from_json(map) do
      %__MODULE__{
        id: map["id"] || map[:id],
        yielded: map["yielded"] || map[:yielded],
        timestamp: Helpers.decode_timestamp(map["timestamp"] || map[:timestamp])
      }
    end

    defimpl Jason.Encoder do
      def encode(entry, opts) do
        map = %{
          "__struct__" => "Elixir.Skuld.Effects.EffectLogger.LogEntry.Suspended",
          "id" => entry.id,
          "yielded" => entry.yielded,
          "timestamp" => Helpers.encode_timestamp(entry.timestamp)
        }

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule Resumed do
    @moduledoc "Suspended effect was resumed with input"
    @enforce_keys [:id, :input, :timestamp]
    defstruct [:id, :input, :timestamp]

    @type t :: %__MODULE__{
            id: String.t(),
            input: term(),
            timestamp: DateTime.t()
          }

    alias Skuld.Effects.EffectLogger.LogEntry.Helpers

    @doc "Decode a JSON-decoded map into a Resumed struct"
    def from_json(map) do
      %__MODULE__{
        id: map["id"] || map[:id],
        input: map["input"] || map[:input],
        timestamp: Helpers.decode_timestamp(map["timestamp"] || map[:timestamp])
      }
    end

    defimpl Jason.Encoder do
      def encode(entry, opts) do
        map = %{
          "__struct__" => "Elixir.Skuld.Effects.EffectLogger.LogEntry.Resumed",
          "id" => entry.id,
          "input" => entry.input,
          "timestamp" => Helpers.encode_timestamp(entry.timestamp)
        }

        Jason.Encode.map(map, opts)
      end
    end
  end

  defmodule Finished do
    @moduledoc "Suspending effect completed after resume(s)"
    @enforce_keys [:id, :result, :timestamp]
    defstruct [:id, :result, :timestamp]

    @type t :: %__MODULE__{
            id: String.t(),
            result: term(),
            timestamp: DateTime.t()
          }

    alias Skuld.Effects.EffectLogger.LogEntry.Helpers

    @doc "Decode a JSON-decoded map into a Finished struct"
    def from_json(map) do
      %__MODULE__{
        id: map["id"] || map[:id],
        result: map["result"] || map[:result],
        timestamp: Helpers.decode_timestamp(map["timestamp"] || map[:timestamp])
      }
    end

    defimpl Jason.Encoder do
      def encode(entry, opts) do
        map = %{
          "__struct__" => "Elixir.Skuld.Effects.EffectLogger.LogEntry.Finished",
          "id" => entry.id,
          "result" => entry.result,
          "timestamp" => Helpers.encode_timestamp(entry.timestamp)
        }

        Jason.Encode.map(map, opts)
      end
    end
  end

  @type t :: Completed.t() | Thrown.t() | Started.t() | Suspended.t() | Resumed.t() | Finished.t()

  @doc """
  Decode a list of JSON-decoded log entries.

  Uses `Skuld.Comp.SerializableStruct.decode/1` which will call the
  appropriate `from_json/1` function based on the `__struct__` field.

  ## Example

      json = Jason.encode!(log)
      decoded_maps = Jason.decode!(json)
      log = Skuld.Effects.EffectLogger.LogEntry.decode_log(decoded_maps)
  """
  @spec decode_log([map()]) :: [t()]
  def decode_log(entries) when is_list(entries) do
    Enum.map(entries, &SerializableStruct.decode/1)
  end
end
