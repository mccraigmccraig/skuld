defmodule Skuld.Effects.Fresh.Test do
  @moduledoc """
  Deterministic v5 UUID handler for Fresh effect - for testing.

  Generates reproducible UUIDs using UUID v5 (name-based, SHA-1) with a
  configured namespace and sequential counter. The same namespace always
  produces the same UUID sequence - ideal for testing.

  ## Example

      namespace = Uniq.UUID.uuid4()

      # First run
      uuid1 = comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.Test.with_handler(namespace: namespace)
      |> Comp.run!()

      # Second run - same result!
      uuid2 = comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.Test.with_handler(namespace: namespace)
      |> Comp.run!()

      uuid1 == uuid2  #=> true
  """

  @behaviour Skuld.Comp.IHandle
  @behaviour Skuld.Comp.IInstall

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Effects.Fresh.FreshUUID

  @sig Skuld.Effects.Fresh

  # Default namespace for deterministic UUID generation (a fixed v4 UUID)
  @default_namespace "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

  defmodule State do
    @moduledoc false
    defstruct counter: 0, namespace: nil
  end

  @doc """
  Install a deterministic UUID handler for testing.

  ## Options

  - `namespace` - UUID namespace for generation (default: a fixed UUID).
    Can be a UUID string or one of the standard namespaces: `:dns`, `:url`,
    `:oid`, `:x500`, or `nil`.
  - `output` - optional function `(result, final_counter) -> new_result`
    to transform the result before returning.

  ## Example

      namespace = Uniq.UUID.uuid4()

      uuid = comp do
        uuid <- Fresh.fresh_uuid()
        return(uuid)
      end
      |> Fresh.Test.with_handler(namespace: namespace)
      |> Comp.run!()
  """
  @spec with_handler(Comp.Types.computation(), keyword()) :: Comp.Types.computation()
  def with_handler(comp, opts \\ []) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    output = Keyword.get(opts, :output)
    suspend = Keyword.get(opts, :suspend)

    initial_state = %State{counter: 0, namespace: namespace}

    # Wrap user's output function to extract counter from state struct
    wrapped_output =
      if output do
        fn value, %State{counter: final_counter} -> output.(value, final_counter) end
      else
        nil
      end

    scoped_opts =
      []
      |> then(fn o -> if wrapped_output, do: Keyword.put(o, :output, wrapped_output), else: o end)
      |> then(fn o -> if suspend, do: Keyword.put(o, :suspend, suspend), else: o end)

    comp
    |> Comp.with_scoped_state(@sig, initial_state, scoped_opts)
    |> Comp.with_handler(@sig, &handle/3)
  end

  @impl Skuld.Comp.IInstall
  def __handle__(comp, opts) when is_list(opts), do: with_handler(comp, opts)
  def __handle__(comp, _config), do: with_handler(comp)

  @impl Skuld.Comp.IHandle
  def handle(%FreshUUID{}, env, k) do
    %State{counter: counter, namespace: namespace} = state = Env.get_state(env, @sig)
    uuid = Uniq.UUID.uuid5(namespace, Integer.to_string(counter))
    new_env = Env.put_state(env, @sig, %{state | counter: counter + 1})
    k.(uuid, new_env)
  end
end
