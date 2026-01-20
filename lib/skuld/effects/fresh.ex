defmodule Skuld.Effects.Fresh do
  @moduledoc """
  Fresh effect - generate fresh/unique UUIDs.

  Provides two handler modes:

  - **Production** (`with_uuid7_handler/1`): Generates v7 UUIDs which are
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

  ## Handler Submodules

  - `Fresh.UUID7` - Production v7 UUID handler
  - `Fresh.Test` - Deterministic v5 UUID handler for testing
  """

  @behaviour Skuld.Comp.IInstall

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @sig __MODULE__

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

  - `with_uuid7_handler/1`: Generates v7 UUIDs (time-ordered, production)
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
  ## Handler Delegation
  #############################################################################

  @doc """
  Install a v7 UUID handler for production use.

  Delegates to `Fresh.UUID7.with_handler/1`.

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
  defdelegate with_uuid7_handler(comp), to: __MODULE__.UUID7, as: :with_handler

  @doc """
  Install a deterministic UUID handler for testing.

  Delegates to `Fresh.Test.with_handler/2`.

  ## Options

  - `namespace` - UUID namespace for generation (default: a fixed UUID).
  - `output` - optional function `(result, final_counter) -> new_result`
    to transform the result before returning.

  ## Example

      namespace = Uniq.UUID.uuid4()

      comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.with_test_handler(namespace: namespace)
      |> Comp.run!()
  """
  @spec with_test_handler(Types.computation(), keyword()) :: Types.computation()
  def with_test_handler(comp, opts \\ []) do
    __MODULE__.Test.with_handler(comp, opts)
  end

  #############################################################################
  ## Catch Clause Installation
  #############################################################################

  @doc """
  Install Fresh handler via catch clause syntax.

  Config selects handler type:

      catch
        Fresh -> :uuid7                      # production handler
        Fresh -> {:test, namespace: ns}      # test handler with opts
        Fresh -> :test                       # test handler, default opts
  """
  @impl Skuld.Comp.IInstall
  def __handle__(comp, :uuid7), do: __MODULE__.UUID7.__handle__(comp, nil)
  def __handle__(comp, :test), do: __MODULE__.Test.__handle__(comp, nil)

  def __handle__(comp, {:test, opts}) when is_list(opts),
    do: __MODULE__.Test.__handle__(comp, opts)
end
