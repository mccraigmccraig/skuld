defmodule Skuld.Effects.Fresh do
  @moduledoc """
  Fresh effect - generate fresh/unique UUIDs.

  Provides two handler modes:

  - **Production** (`with_uuid7_handler/2`): Generates v7 UUIDs which are
    time-ordered and suitable for database primary keys (good data locality,
    lexical ordering).

  - **Test** (`with_test_handler/2`): Generates deterministic v5 UUIDs based
    on a namespace and counter, making sequences reproducible for testing.

  ## Production Usage

      use Skuld.Syntax
      alias Skuld.Comp
      alias Skuld.Effects.Fresh

      comp do
        id1 <- Fresh.fresh_uuid()
        id2 <- Fresh.fresh_uuid()
        return({id1, id2})
      end
      |> Fresh.with_uuid7_handler()
      |> Comp.run!()
      #=> {"01945a3b-...", "01945a3b-..."}  # time-ordered v7 UUIDs

  ## Test Usage (Deterministic)

      # Same namespace produces same UUID sequence - reproducible tests
      namespace = Uniq.UUID.uuid4()

      comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.with_test_handler(namespace: namespace)
      |> Comp.run!()
      #=> "550e8400-..."  # deterministic v5 UUID

      # Running again with same namespace produces same result
      comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.with_test_handler(namespace: namespace)
      |> Comp.run!()
      #=> "550e8400-..."  # same UUID!
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  # Default namespace for deterministic UUID generation (a fixed v4 UUID)
  @default_namespace "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

  #############################################################################
  ## State Structures
  #############################################################################

  defmodule TestState do
    @moduledoc false
    defstruct counter: 0, namespace: nil
  end

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(FreshUUID)

  #############################################################################
  ## Operations
  #############################################################################

  @doc """
  Generate a fresh UUID.

  The UUID format depends on the installed handler:

  - `with_uuid7_handler/2`: Generates v7 UUIDs (time-ordered, production)
  - `with_test_handler/2`: Generates v5 UUIDs (deterministic, testing)

  ## Example

      comp do
        uuid1 <- Fresh.fresh_uuid()
        uuid2 <- Fresh.fresh_uuid()
        return({uuid1, uuid2})
      end
      |> Fresh.with_uuid7_handler()
      |> Comp.run!()
  """
  @spec fresh_uuid() :: Types.computation()
  def fresh_uuid do
    Comp.effect(@sig, %FreshUUID{})
  end

  #############################################################################
  ## Production Handler (v7 UUIDs)
  #############################################################################

  @doc """
  Install a v7 UUID handler for production use.

  Generates time-ordered UUIDs using UUID v7 (RFC 9562). These UUIDs:
  - Are time-ordered (lexically sortable by creation time)
  - Have excellent database index locality
  - Are suitable for distributed systems

  ## Example

      comp do
        id <- Fresh.fresh_uuid()
        return(id)
      end
      |> Fresh.with_uuid7_handler()
      |> Comp.run!()
      #=> "01945a3b-7c9d-7000-8000-..."  # v7 UUID
  """
  @spec with_uuid7_handler(Types.computation()) :: Types.computation()
  def with_uuid7_handler(comp) do
    Comp.with_handler(comp, @sig, &handle_uuid7/3)
  end

  defp handle_uuid7(%FreshUUID{}, env, k) do
    uuid = Uniq.UUID.uuid7()
    k.(uuid, env)
  end

  #############################################################################
  ## Test Handler (Deterministic v5 UUIDs)
  #############################################################################

  @doc """
  Install a deterministic UUID handler for testing.

  Generates reproducible UUIDs using UUID v5 (name-based, SHA-1) with a
  configured namespace and sequential counter. The same namespace always
  produces the same UUID sequence - ideal for testing.

  ## Options

  - `namespace` - UUID namespace for generation (default: a fixed UUID).
    Can be a UUID string or one of the standard namespaces: `:dns`, `:url`,
    `:oid`, `:x500`, or `nil`.
  - `output` - optional function `(result, final_counter) -> new_result`
    to transform the result before returning.

  ## Example

      namespace = Uniq.UUID.uuid4()

      # First run
      uuid1 = comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.with_test_handler(namespace: namespace)
      |> Comp.run!()

      # Second run - same result!
      uuid2 = comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.with_test_handler(namespace: namespace)
      |> Comp.run!()

      uuid1 == uuid2  #=> true
  """
  @spec with_test_handler(Types.computation(), keyword()) :: Types.computation()
  def with_test_handler(comp, opts \\ []) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    output = Keyword.get(opts, :output)

    initial_state = %TestState{counter: 0, namespace: namespace}

    # Wrap user's output function to extract counter from state struct
    wrapped_output =
      if output do
        fn value, %TestState{counter: final_counter} -> output.(value, final_counter) end
      else
        nil
      end

    opts = if wrapped_output, do: [output: wrapped_output], else: []

    comp
    |> Comp.with_scoped_state(@sig, initial_state, opts)
    |> Comp.with_handler(@sig, &handle_test/3)
  end

  defp handle_test(%FreshUUID{}, env, k) do
    %TestState{counter: counter, namespace: namespace} = state = Env.get_state(env, @sig)
    uuid = Uniq.UUID.uuid5(namespace, Integer.to_string(counter))
    new_env = Env.put_state(env, @sig, %{state | counter: counter + 1})
    k.(uuid, new_env)
  end

  #############################################################################
  ## IHandler Implementation (not used directly - handlers use private fns)
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(%FreshUUID{}, _env, _k) do
    raise "Fresh.handle/3 should not be called directly - use with_uuid7_handler/2 or with_test_handler/2"
  end
end
