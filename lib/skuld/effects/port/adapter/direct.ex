defmodule Skuld.Effects.Port.Adapter.Direct do
  @moduledoc """
  Macro for delegating through a port contract to a plain Elixir implementation.

  A direct adapter generates plain Elixir functions that delegate to an
  implementation module, with no Skuld computation machinery involved. Both
  caller and implementation deal in plain values.

  This enables imposing a hexagonal boundary on legacy code without introducing
  any Skuld concepts — the contract defines the interface, the adapter enforces
  it at compile time via `@behaviour`, and calls are simple delegation.

  ## Options

    * `:contract` — the Port.Contract module (required)
    * `:impl` — the Plain-behaviour implementation module (required)

  ## Example

      # Contract defines the port
      defmodule MyApp.UserService do
        use Skuld.Effects.Port.Contract
        defport find_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()}
      end

      # Plain implementation satisfies Plain behaviour
      defmodule MyApp.UserService.Ecto do
        @behaviour MyApp.UserService.Plain

        @impl true
        def find_user(id) do
          case Repo.get(User, id) do
            nil -> {:error, :not_found}
            user -> {:ok, user}
          end
        end
      end

      # Direct adapter delegates through contract to plain impl
      defmodule MyApp.UserService.Direct do
        use Skuld.Effects.Port.Adapter.Direct,
          contract: MyApp.UserService,
          impl: MyApp.UserService.Ecto
      end

      # Plain Elixir in, plain Elixir out — no computations, no effects
      MyApp.UserService.Direct.find_user("user-123")
      # => {:ok, %User{...}}

  ## How It Works

  For each operation defined in the contract (via `__port_operations__/0`), the
  adapter generates a function that delegates to the implementation module.

  The generated module declares `@behaviour ContractModule.Plain`, ensuring
  compile-time verification that all required callbacks are implemented.

  ## Hexagonal Architecture

  In hexagonal architecture terms, this covers the **Legacy→Plain** scenario:
  legacy code calls a plain implementation through a contract boundary. Neither
  side knows about Skuld.

  This is the first step in incremental adoption:

  1. Define a contract (`defport` declarations)
  2. Wire legacy callers through `Port.Adapter.Direct`
  3. Later, convert consumers to Skuld (`Port.with_handler`) or providers to
     Skuld (`Port.Adapter.Effectful`) independently

  ## Swapping Implementations

  Since the adapter delegates to the `:impl` module, you can swap implementations
  by pointing to a different module:

      # Production
      defmodule MyApp.UserService.Live do
        use Skuld.Effects.Port.Adapter.Direct,
          contract: MyApp.UserService,
          impl: MyApp.UserService.Ecto
      end

      # Test
      defmodule MyApp.UserService.Test do
        use Skuld.Effects.Port.Adapter.Direct,
          contract: MyApp.UserService,
          impl: MyApp.UserService.InMemory
      end

  Since the adapter itself satisfies the Plain behaviour, it can also be used
  as a handler target in `Port.with_handler/2` when Skuld consumers call through
  the same contract.
  """

  defmacro __using__(opts) do
    contract = Keyword.fetch!(opts, :contract)
    impl = Keyword.fetch!(opts, :impl)

    quote do
      @before_compile {Skuld.Effects.Port.Adapter.Direct, :__before_compile__}
      @__port_direct_contract__ unquote(contract)
      @__port_direct_impl__ unquote(impl)
    end
  end

  defmacro __before_compile__(env) do
    contract = Module.get_attribute(env.module, :__port_direct_contract__)
    impl = Module.get_attribute(env.module, :__port_direct_impl__)

    # Validate contract module has __port_operations__/0
    unless function_exported?(contract, :__port_operations__, 0) do
      raise CompileError,
        description:
          "#{inspect(contract)} does not appear to be a Port.Contract module " <>
            "(missing __port_operations__/0). Ensure it uses Skuld.Effects.Port.Contract " <>
            "and defines at least one defport.",
        file: env.file,
        line: 0
    end

    plain_behaviour = Module.concat(contract, Plain)
    operations = contract.__port_operations__()

    functions =
      Enum.map(operations, fn %{name: name, params: param_names} ->
        param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)

        quote do
          @impl true
          def unquote(name)(unquote_splicing(param_vars)) do
            unquote(impl).unquote(name)(unquote_splicing(param_vars))
          end
        end
      end)

    quote do
      @behaviour unquote(plain_behaviour)
      def __port_effectful__?, do: false
      unquote_splicing(functions)
    end
  end
end
