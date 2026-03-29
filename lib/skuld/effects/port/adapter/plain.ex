defmodule Skuld.Effects.Port.Adapter.Plain do
  @moduledoc """
  Macro for creating a config-dispatched plain adapter for a port contract.

  A plain adapter generates plain Elixir functions that delegate to an
  implementation module resolved from application config at runtime. Both
  caller and implementation deal in plain values — no Skuld computation
  machinery is involved.

  This enables imposing a hexagonal boundary on existing code without
  introducing any Skuld concepts. The adapter is the single dispatch
  point: production config points it at the real implementation, test
  config points it at a Mox mock.

  ## Options

    * `:contract` — the Port.Contract module (required)
    * `:otp_app` — the OTP application for config lookup (required)
    * `:config_key` — the config key (optional, defaults to the adapter
      module name as a snake_case atom)
    * `:default` — default implementation module when no config is set
      (optional)

  ## Example

      # Contract defines the port
      defmodule MyApp.UserService do
        use Skuld.Effects.Port.Contract
        defport find_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()}
      end

      # Plain implementation satisfies Behaviour
      defmodule MyApp.UserService.Ecto do
        @behaviour MyApp.UserService.Behaviour

        @impl true
        def find_user(id) do
          case Repo.get(User, id) do
            nil -> {:error, :not_found}
            user -> {:ok, user}
          end
        end
      end

      # Plain adapter — dispatches to config-resolved impl
      defmodule MyApp.UserService.Adapter do
        use Skuld.Effects.Port.Adapter.Plain,
          contract: MyApp.UserService,
          otp_app: :my_app,
          default: MyApp.UserService.Ecto
      end

      # Plain Elixir in, plain Elixir out — no computations, no effects
      MyApp.UserService.Adapter.find_user("user-123")
      # => {:ok, %User{...}}

  ## Config-based dispatch

  The adapter resolves the implementation module at runtime via
  `Application.get_env/3`:

      # config/config.exs (or config/prod.exs, config/dev.exs)
      config :my_app, MyApp.UserService.Adapter, MyApp.UserService.Ecto

      # config/test.exs — swap to Mox mock
      config :my_app, MyApp.UserService.Adapter, MyApp.UserService.Mock

  The generated `impl/0` function is public, so tests can verify
  which implementation is active.

  ## Testing with Mox

  The contract's generated `Behaviour` is exactly what Mox needs:

      # test/support/mocks.ex
      Mox.defmock(MyApp.UserService.Mock, for: MyApp.UserService.Behaviour)

      # config/test.exs
      config :my_app, MyApp.UserService.Adapter, MyApp.UserService.Mock

      # In tests
      import Mox
      setup :verify_on_exit!

      test "find_user returns user" do
        expect(MyApp.UserService.Mock, :find_user, fn "user-123" ->
          {:ok, %User{id: "user-123"}}
        end)

        assert {:ok, %User{}} = MyApp.UserService.Adapter.find_user("user-123")
      end

  ## Hexagonal Architecture

  In hexagonal architecture terms, this covers the **Plain→Plain** scenario:
  plain code calls a plain implementation through a contract boundary.
  Neither side knows about Skuld.

  This is the first step in incremental adoption:

  1. Define a contract (`defport` declarations)
  2. Wire callers through `Port.Adapter.Plain`
  3. Use Mox in tests for isolation
  4. Later, replace with `Port.Adapter.Effectful` to switch to an
     effectful implementation — callers don't change

  ## Migration to Effectful

  When you're ready to convert to an effectful implementation, replace
  `use Port.Adapter.Plain` with `use Port.Adapter.Effectful` and
  provide a handler stack. The adapter's public API doesn't change,
  so callers are unaffected.

  Since the adapter satisfies the Plain behaviour, it can also be used
  as a handler target in `Port.with_handler/2` when Skuld consumers
  call through the same contract.
  """

  defmacro __using__(opts) do
    contract = Keyword.fetch!(opts, :contract)
    otp_app = Keyword.fetch!(opts, :otp_app)
    config_key = Keyword.get(opts, :config_key)
    default = Keyword.get(opts, :default)

    quote do
      @before_compile {Skuld.Effects.Port.Adapter.Plain, :__before_compile__}
      @__port_plain_contract__ unquote(contract)
      @__port_plain_otp_app__ unquote(otp_app)
      @__port_plain_config_key__ unquote(config_key)
      @__port_plain_default__ unquote(default)
    end
  end

  defmacro __before_compile__(env) do
    contract = Module.get_attribute(env.module, :__port_plain_contract__)
    otp_app = Module.get_attribute(env.module, :__port_plain_otp_app__)
    config_key = Module.get_attribute(env.module, :__port_plain_config_key__) || env.module
    default = Module.get_attribute(env.module, :__port_plain_default__)

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

    plain_behaviour = Module.concat(contract, Behaviour)
    operations = contract.__port_operations__()

    impl_fn =
      if default do
        quote do
          @doc """
          Returns the current implementation module.

          Resolved from `Application.get_env(#{inspect(unquote(otp_app))}, #{inspect(unquote(config_key))})`,
          defaulting to `#{inspect(unquote(default))}`.
          """
          def impl do
            Application.get_env(unquote(otp_app), unquote(config_key), unquote(default))
          end
        end
      else
        quote do
          @doc """
          Returns the current implementation module.

          Resolved from `Application.fetch_env!(#{inspect(unquote(otp_app))}, #{inspect(unquote(config_key))})`.
          Raises if not configured.
          """
          def impl do
            Application.fetch_env!(unquote(otp_app), unquote(config_key))
          end
        end
      end

    functions =
      Enum.map(operations, fn %{name: name, params: param_names} ->
        param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)

        quote do
          @impl true
          def unquote(name)(unquote_splicing(param_vars)) do
            impl().unquote(name)(unquote_splicing(param_vars))
          end
        end
      end)

    quote do
      @behaviour unquote(plain_behaviour)
      unquote(impl_fn)
      unquote_splicing(functions)
    end
  end
end
