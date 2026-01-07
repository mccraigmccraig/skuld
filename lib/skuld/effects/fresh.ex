defmodule Skuld.Effects.Fresh do
  @moduledoc """
  Fresh effect - generate fresh/unique values.

  Provides sequential integers and deterministic UUIDs (v5) for generating
  unique identifiers. The UUID generation uses a namespace UUID combined
  with the counter value, making sequences reproducible given the same
  namespace - ideal for testing.

  ## Example

      use Skuld.Syntax
      alias Skuld.Comp
      alias Skuld.Effects.Fresh

      comp do
        id1 <- Fresh.fresh()
        id2 <- Fresh.fresh()
        uuid1 <- Fresh.fresh_uuid()
        uuid2 <- Fresh.fresh_uuid()
        return(%{ids: {id1, id2}, uuids: {uuid1, uuid2}})
      end
      |> Fresh.with_handler()
      |> Comp.run!()
      #=> %{ids: {0, 1}, uuids: {"...", "..."}}

  ## Reproducible UUIDs

  The same namespace UUID produces the same UUID sequence:

      namespace = Uniq.UUID.uuid4()

      # First run
      comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.with_handler(namespace: namespace)
      |> Comp.run!()
      #=> "abc123..."

      # Second run with same namespace - same result!
      comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.with_handler(namespace: namespace)
      |> Comp.run!()
      #=> "abc123..."
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  # Default namespace for UUID generation (a fixed v4 UUID)
  @default_namespace "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

  #############################################################################
  ## State Structure
  #############################################################################

  defmodule State do
    @moduledoc false
    defstruct counter: 0, namespace: nil
  end

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Fresh)
  def_op(FreshUUID)

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Generate the next fresh integer.

  Returns sequential integers starting from the initial value (default 0).

  ## Example

      comp do
        a <- Fresh.fresh()
        b <- Fresh.fresh()
        c <- Fresh.fresh()
        return({a, b, c})
      end
      |> Fresh.with_handler()
      |> Comp.run!()
      #=> {0, 1, 2}
  """
  @spec fresh() :: Types.computation()
  def fresh do
    Comp.effect(@sig, %Fresh{})
  end

  @doc """
  Generate the next fresh UUID (v5).

  Uses UUID v5 (name-based, SHA-1) with the configured namespace UUID
  and the current counter value as the name. This produces deterministic,
  reproducible UUIDs - the same namespace and counter always produce the
  same UUID.

  ## Example

      comp do
        uuid1 <- Fresh.fresh_uuid()
        uuid2 <- Fresh.fresh_uuid()
        return({uuid1, uuid2})
      end
      |> Fresh.with_handler(namespace: "my-namespace-uuid")
      |> Comp.run!()
      #=> {"550e8400-...", "6ba7b810-..."}
  """
  @spec fresh_uuid() :: Types.computation()
  def fresh_uuid do
    Comp.effect(@sig, %FreshUUID{})
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped Fresh handler for a computation.

  ## Options

  - `seed` - initial counter value (default: 0)
  - `namespace` - UUID namespace for `fresh_uuid/0` (default: a fixed UUID).
    Can be a UUID string or one of the standard namespaces: `:dns`, `:url`,
    `:oid`, `:x500`, or `nil`.
  - `output` - optional function `(result, final_counter) -> new_result`
    to transform the result before returning.

  ## Examples

      # Basic usage
      comp do
        id <- Fresh.fresh()
        return(id)
      end
      |> Fresh.with_handler()
      |> Comp.run!()
      #=> 0

      # Start from a different value (seed the counter)
      comp do
        id <- Fresh.fresh()
        return(id)
      end
      |> Fresh.with_handler(seed: 100)
      |> Comp.run!()
      #=> 100

      # Custom namespace for reproducible UUIDs
      namespace = Uniq.UUID.uuid4()
      comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.with_handler(namespace: namespace)
      |> Comp.run!()

      # Include final counter in result
      comp do
        _ <- Fresh.fresh()
        _ <- Fresh.fresh()
        return(:done)
      end
      |> Fresh.with_handler(output: fn result, counter -> {result, counter} end)
      |> Comp.run!()
      #=> {:done, 2}
  """
  @spec with_handler(Types.computation(), keyword()) :: Types.computation()
  def with_handler(comp, opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    output = Keyword.get(opts, :output)

    initial_state = %State{counter: seed, namespace: namespace}

    comp
    |> Comp.scoped(fn env ->
      previous = Env.get_state(env, @sig)
      modified = Env.put_state(env, @sig, initial_state)

      finally_k = fn value, e ->
        %State{counter: final_counter} = Env.get_state(e, @sig)

        restored_env =
          case previous do
            nil -> %{e | state: Map.delete(e.state, @sig)}
            val -> Env.put_state(e, @sig, val)
          end

        transformed_value =
          if output do
            output.(value, final_counter)
          else
            value
          end

        {transformed_value, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  @doc "Get the current counter value from an env"
  @spec get_counter(Types.env()) :: non_neg_integer()
  def get_counter(env) do
    case Env.get_state(env, @sig) do
      %State{counter: counter} -> counter
      nil -> 0
    end
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(%Fresh{}, env, k) do
    %State{counter: counter} = state = Env.get_state(env, @sig)
    new_env = Env.put_state(env, @sig, %{state | counter: counter + 1})
    k.(counter, new_env)
  end

  @impl Skuld.Comp.IHandler
  def handle(%FreshUUID{}, env, k) do
    %State{counter: counter, namespace: namespace} = state = Env.get_state(env, @sig)
    uuid = Uniq.UUID.uuid5(namespace, Integer.to_string(counter))
    new_env = Env.put_state(env, @sig, %{state | counter: counter + 1})
    k.(uuid, new_env)
  end
end
