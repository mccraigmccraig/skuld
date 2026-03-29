defmodule Skuld.Effects.Port.Adapter.Effectful do
  @moduledoc """
  Macro for bridging effectful implementations to plain Elixir interfaces.

  An effectful adapter wraps an effectful implementation module — one whose
  functions return `computation(return_type)` — with a handler stack and
  `Comp.run!/1`, producing a module that satisfies the Plain behaviour with
  plain Elixir functions.

  ## Options

    * `:contract` — the Port.Contract module (required)
    * `:impl` — the Effectful-behaviour implementation module (required)
    * `:stack` — a function `(computation -> computation)` that installs the
      handler stack (required)

  ## Example

      # Contract defines the port
      defmodule MyApp.UserService do
        use Skuld.Effects.Port.Contract
        defport find_user(id :: String.t()) :: {:ok, User.t()} | {:error, term()}
      end

      # Effectful implementation satisfies Effectful behaviour
      defmodule MyApp.UserService.EffectfulImpl do
        @behaviour MyApp.UserService.Effectful
        defcomp find_user(id) do
          user <- MyApp.UserRepo.get(id)
          {:ok, user}
        end
      end

      # Effectful adapter satisfies Plain behaviour, runs effectful impl
      defmodule MyApp.UserService.Adapter do
        use Skuld.Effects.Port.Adapter.Effectful,
          contract: MyApp.UserService,
          impl: MyApp.UserService.EffectfulImpl,
          stack: &MyApp.Stacks.user_service/1
      end

      # Now MyApp.UserService.Adapter can be used as a plain implementation:
      MyApp.UserService.Adapter.find_user("user-123")
      # => {:ok, %User{...}}

  ## How It Works

  For each operation defined in the contract (via `__port_operations__/0`), the
  adapter generates a function that:

  1. Calls the impl module's corresponding function to get a computation
  2. Pipes through the stack function to install effect handlers
  3. Runs the computation with `Comp.run!/1`

  The generated module declares `@behaviour ContractModule.Behaviour`, ensuring
  compile-time verification that all required callbacks are implemented.

  ## Hexagonal Architecture

  In hexagonal architecture terms, there are four scenarios for a port contract:

    * **Skuld→Plain** — effectful code calls out to plain Elixir implementations
      through the Port effect, resolved by `Port.with_handler/2` at runtime.
    * **Skuld→Effectful** — effectful code calls out to effectful implementations
      through the Port effect with an `:effectful` resolver.
    * **Legacy→Plain** — plain Elixir code calls plain implementations through
      the HexPort-generated `X.Port` facade or `Port.Adapter.Plain`.
    * **Legacy→Effectful** — plain Elixir code calls into effectful implementations
      through this adapter (`Port.Adapter.Effectful`), which runs the effectful
      code with a handler stack, producing plain return values.

  ## Throw handler in the stack

  If the effectful implementation can throw (via `Skuld.Effects.Throw`), the
  stack function **must** install a `Throw.with_handler/1`. Without it,
  `Comp.run!/1` raises `Skuld.Comp.ThrowError`, which can be confusing if you
  don't realise a Throw handler is missing from the stack.

  A minimal stack that only handles throws:

      use Skuld.Effects.Port.Adapter.Effectful,
        contract: MyContract,
        impl: MyEffectfulImpl,
        stack: &Skuld.Effects.Throw.with_handler/1

  For stacks with multiple effects, place `Throw.with_handler/1` last (outermost)
  so it catches throws from all inner handlers:

      stack: fn comp ->
        comp
        |> State.with_handler(initial_state)
        |> Transaction.Ecto.with_handler(MyApp.Repo)
        |> Throw.with_handler()
      end

  ## Testing Effectful Adapters

  Effectful adapters produce plain Elixir values, so they can be tested directly
  without effect machinery:

      test "adapter returns expected result" do
        result = MyApp.UserService.Adapter.find_user("user-123")
        assert {:ok, %User{id: "user-123"}} = result
      end

  To test the effectful implementation in isolation (without the adapter), use
  the standard effect testing patterns — install handlers and run the computation:

      test "effectful impl with handlers" do
        comp =
          MyApp.UserService.EffectfulImpl.find_user("user-123")
          |> MyApp.UserRepo.with_test_handler(...)
          |> Throw.with_handler()

        {result, _env} = Comp.run(comp)
        assert {:ok, %User{}} = result
      end

  Since the adapter satisfies the Behaviour, it can also be used as a handler
  target in `Port.with_handler/2`, enabling effectful-to-effectful composition
  through the Port system.
  """

  defmacro __using__(opts) do
    contract = Keyword.fetch!(opts, :contract)
    impl = Keyword.fetch!(opts, :impl)
    stack_ast = Keyword.fetch!(opts, :stack)

    # Store stack as escaped AST so it survives module attribute storage
    # and can be re-injected in __before_compile__
    escaped_stack = Macro.escape(stack_ast)

    quote do
      @before_compile {Skuld.Effects.Port.Adapter.Effectful, :__before_compile__}
      @__port_provider_contract__ unquote(contract)
      @__port_provider_impl__ unquote(impl)
      @__port_provider_stack_ast__ unquote(escaped_stack)
    end
  end

  defmacro __before_compile__(env) do
    contract = Module.get_attribute(env.module, :__port_provider_contract__)
    impl = Module.get_attribute(env.module, :__port_provider_impl__)
    stack_ast = Module.get_attribute(env.module, :__port_provider_stack_ast__)

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

    functions =
      Enum.map(operations, fn %{name: name, params: param_names} ->
        param_vars = Enum.map(param_names, fn pname -> {pname, [], nil} end)

        quote do
          @impl true
          def unquote(name)(unquote_splicing(param_vars)) do
            unquote(impl).unquote(name)(unquote_splicing(param_vars))
            |> unquote(stack_ast).()
            |> Skuld.Comp.run!()
          end
        end
      end)

    quote do
      @behaviour unquote(plain_behaviour)
      unquote_splicing(functions)
    end
  end
end
