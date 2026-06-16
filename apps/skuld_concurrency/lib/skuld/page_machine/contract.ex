defmodule Skuld.PageMachine.Contract do
  @moduledoc """
  Typed protocol contract for PageMachine spindle ↔ LiveView communication.

  `use Skuld.PageMachine.Contract` imports `defevent` and `defyield` macros
  to declare the typed interface between a page's spindles and its LiveView.

  Each declaration is validated at compile time. The protocol module acts as
  the single source of truth for event routing and yield shapes.

  ## Usage

      defmodule MyApp.StoreProtocol do
        use Skuld.PageMachine.Contract

        defevent "search", into: :products, params: [query: String.t()]
        defevent "buy", into: :products

        defyield :products, :browsing
        defyield :products, :results, params: [products: [Product.t()], total: integer()]
        defyield :checkout, :shipping
        defyield :checkout, :payment
      end

  ## Generated Types and Functions

  For each `defyield` with `params:`, a nested struct module is generated:

      defmodule StoreProtocol.Products.Results do
        @type t :: %__MODULE__{products: [Product.t()], total: integer()}
        defstruct products: nil, total: nil
      end

  The protocol module gains `yield/2` helpers:

      StoreProtocol.yield(:products, :results, %{products: prods, total: n})

  ## Integration with PageMachine

      use Skuld.PageMachine,
        protocol: MyApp.StoreProtocol,
        on_yield: &handle_yield/3

  The `:protocol` option enables compile-time validation of `def_pipe_event`
  declarations and generates them automatically from the protocol's events.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Skuld.PageMachine.Contract,
        only: [defevent: 2, defyield: 2, defyield: 3]

      Module.register_attribute(__MODULE__, :pm_events, accumulate: true)
      Module.register_attribute(__MODULE__, :pm_yields, accumulate: true)
      @before_compile Skuld.PageMachine.Contract
    end
  end

  @doc """
  Declare a LiveView event routed to a spindle.

  ## Syntax

      defevent event_name, into: spindle_key
      defevent event_name, into: spindle_key, params: [field: type(), ...]

  ## Examples

      defevent "search", into: :products
      defevent "search", into: :products, params: [query: String.t()]
      defevent "buy", into: :products, params: [product: Product.t(), quantity: integer()]
  """
  defmacro defevent(event_name, opts) when is_binary(event_name) do
    into = Keyword.fetch!(opts, :into)
    params = Keyword.get(opts, :params)
    event_name = clean_event_name(event_name)

    event = %{
      event: event_name,
      into: into,
      params: params || []
    }

    escaped = Macro.escape(event)

    quote do
      unless is_atom(unquote(into)) do
        raise CompileError, "defevent :into must be an atom, got: #{inspect(unquote(into))}"
      end

      @pm_events unquote(escaped)
    end
  end

  @doc """
  Declare a yield from a spindle to the LiveView.

  ## Syntax

      defyield spindle_key, tag
      defyield spindle_key, tag, params: [field: type(), ...]

  ## Examples

      defyield :products, :browsing
      defyield :products, :results, params: [products: [Product.t()], total: integer()]
      defyield :checkout, :shipping
  """
  defmacro defyield(spindle_key, tag, opts \\ []) when is_atom(spindle_key) and is_atom(tag) do
    params = Keyword.get(opts, :params)

    yield = %{
      spindle: spindle_key,
      tag: tag,
      params: params || []
    }

    escaped = Macro.escape(yield)

    quote do
      @pm_yields unquote(escaped)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    events = Module.get_attribute(env.module, :pm_events) |> Enum.reverse()
    yields = Module.get_attribute(env.module, :pm_yields) |> Enum.reverse()

    validate_events!(events, env)
    validate_yields!(yields, env)

    struct_modules = Enum.map(yields, &generate_struct_module(env.module, &1))
    yield_helpers = generate_yield_helpers(env.module, yields)
    introspection = generate_introspection(events, yields)
    event_list = generate_event_list(env.module, events)

    quote do
      unquote_splicing(struct_modules)
      unquote(yield_helpers)
      unquote(introspection)
      unquote(event_list)
    end
  end

  defp validate_events!(events, env) do
    if events == [] do
      raise CompileError,
        description:
          "#{inspect(env.module)} has no defevent declarations. " <>
            "Add at least one defevent to define the LiveView → spindle event contract.",
        file: env.file
    end

    Enum.each(events, fn %{event: event, into: into} ->
      unless is_binary(event) and byte_size(event) > 0 do
        raise CompileError,
          description: "defevent event name must be a non-empty string",
          file: env.file
      end

      unless is_atom(into) do
        raise CompileError,
          description: "defevent :into must be an atom, got: #{inspect(into)}",
          file: env.file
      end
    end)

    event_names = Enum.map(events, & &1.event)
    unique = MapSet.new(event_names) |> MapSet.size()

    if unique != length(event_names) do
      dups = event_names -- Enum.uniq(event_names)

      raise CompileError,
        description: "Duplicate event names: #{inspect(dups)}",
        file: env.file
    end
  end

  defp validate_yields!(yields, env) do
    if yields == [] do
      raise CompileError,
        description:
          "#{inspect(env.module)} has no defyield declarations. " <>
            "Add at least one defyield to define the spindle → LiveView yield contract.",
        file: env.file
    end

    tag_pairs = Enum.map(yields, fn %{spindle: s, tag: t} -> {s, t} end)
    unique = MapSet.new(tag_pairs) |> MapSet.size()

    if unique != length(yields) do
      dups = tag_pairs -- Enum.uniq(tag_pairs)

      raise CompileError,
        description: "Duplicate spindle/tag pairs in defyield: #{inspect(dups)}",
        file: env.file
    end
  end

  defp generate_struct_module(protocol_module, %{spindle: spindle, tag: tag, params: params}) do
    if params == [] do
      nil
    else
      struct_name = combine_atom_names(spindle, tag)
      struct_module = Module.concat(protocol_module, struct_name)

      fields = Enum.map(params, fn {name, _type} -> name end)
      field_defaults = Enum.map(fields, &{&1, nil})

      type_spec =
        Enum.map(params, fn {name, type} ->
          {name, type}
        end)

      quote do
        defmodule unquote(struct_module) do
          @moduledoc false

          @type t :: %__MODULE__{
                  unquote_splicing(type_spec)
                }

          defstruct unquote(field_defaults)
        end
      end
    end
  end

  defp generate_yield_helpers(protocol_module, yields) do
    has_yield_with_params? = Enum.any?(yields, fn %{params: p} -> p != [] end)

    if has_yield_with_params? do
      clauses =
        Enum.map(yields, fn %{spindle: spindle, tag: tag, params: params} ->
          if params != [] do
            struct_name = combine_atom_names(spindle, tag)
            struct_module = Module.concat(protocol_module, struct_name)

            quote do
              def yield(unquote(spindle), unquote(tag), %{} = fields) do
                struct = struct(unquote(struct_module), fields)
                Skuld.Effects.Yield.yield(struct)
              end
            end
          end
        end)
        |> Enum.filter(& &1)

      quote do
        @doc """
        Yield a typed value from a spindle to the LiveView.

        Builds a typed yield struct from the field map and calls `Yield.yield/1`.
        Only `defyield` declarations with `params:` get a typed yield helper clause.

        ## Example

            StoreProtocol.yield(:products, :results, %{products: prods, total: n})
        """
        @spec yield(atom(), atom(), map()) :: Skuld.Comp.Types.computation()
        unquote_splicing(clauses)

        def yield(spindle, tag, _fields) do
          raise ArgumentError,
                "no defyield with params for #{inspect(spindle)}/#{inspect(tag)} in #{inspect(unquote(protocol_module))}"
        end
      end
    end
  end

  defp generate_introspection(events, yields) do
    escaped_events = Macro.escape(events)
    escaped_yields = Macro.escape(yields)

    quote do
      @doc """
      Returns the list of defevent declarations as maps.
      """
      @spec __protocol_events__() :: [map()]
      def __protocol_events__, do: unquote(escaped_events)

      @doc """
      Returns the list of defyield declarations as maps.
      """
      @spec __protocol_yields__() :: [map()]
      def __protocol_yields__, do: unquote(escaped_yields)
    end
  end

  defp generate_event_list(_protocol_module, events) do
    entries =
      Enum.map(events, fn %{event: event, into: into, params: params} ->
        {event, into, params}
      end)

    escaped = Macro.escape(entries)

    quote do
      @doc false
      def __pm_events__, do: unquote(escaped)
    end
  end

  @doc false
  def combine_atom_names(a, b) do
    pascal = fn atom ->
      atom
      |> Atom.to_string()
      |> String.split("_")
      |> Enum.map_join(fn s -> String.capitalize(s) end)
    end

    (pascal.(a) <> pascal.(b))
    |> String.to_atom()
  end

  defp clean_event_name(event) when is_binary(event), do: event
end
