defmodule Skuld.PageMachine.Contract do
  @moduledoc """
  Typed protocol contract for PageMachine spindle ↔ LiveView communication.

  `use Skuld.PageMachine.Contract` imports `defspindle`, `defevent`,
  and `defyield` macros to declare the typed interface between a page's
  spindles and its LiveView.

  Each declaration is validated at compile time. The protocol module acts
  as the single source of truth for event routing and yield shapes.

  ## Usage

      defmodule MyApp.StoreProtocol do
        use Skuld.PageMachine.Contract

        defspindle Products do
          defevent "search", SearchEvent, params: [query: String.t()]
          defevent "filter", FilterEvent, params: [filters: map()]
          defevent "buy"

          defyield :browsing
          defyield :results, params: [products: [Product.t()], total: integer()]
        end

        defspindle Checkout do
          defevent "submit_shipping", ShippingEvent, params: [shipping: map()]
          defevent "submit_payment", PaymentEvent, params: [payment: map()]

          defyield :shipping
          defyield :payment
        end
      end

  Events with an explicit struct name generate a typed struct module
  under the spindle module (`StoreProtocol.Products.SearchEvent`).
  The auto-generated `handle_event` wraps params into the struct before
  resuming the spindle, giving typed receive-side pattern matching.

  Events without a struct name pass `{event_name, params}` as the
  resume value (LiveView convention).

  The spindle key is the module atom (`StoreProtocol.Products`) — the
  same module where yield functions are generated:

      StoreProtocol.Products.results(products: prods, total: n)
      StoreProtocol.Checkout.shipping()

  ## Integration with PageMachine

      use Skuld.PageMachine,
        protocol: MyApp.StoreProtocol,
        on_yield: &handle_yield/3

  The `:protocol` option auto-generates `handle_event/3` clauses from
  the protocol's event declarations.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Skuld.PageMachine.Contract,
        only: [
          defspindle: 2,
          defevent: 1,
          defevent: 2,
          defevent: 3,
          defyield: 1,
          defyield: 2
        ]

      Module.register_attribute(__MODULE__, :pm_events, accumulate: true)
      Module.register_attribute(__MODULE__, :pm_yields, accumulate: true)
      Module.register_attribute(__MODULE__, :pm_spindles, accumulate: true)
      @before_compile Skuld.PageMachine.Contract
    end
  end

  @doc """
  Open a spindle block.

  Inside the block, `defevent` and `defyield` infer the spindle from the
  enclosing `defspindle` context — no need to repeat the spindle key.

  The spindle name becomes the module atom under the protocol module
  (e.g., `defspindle Products` → `StoreProtocol.Products`), which is
  both the spindle key for event routing and the module where typed
  yield functions are generated.

  ## Example

      defspindle Products do
        defevent "search", SearchEvent, params: [query: String.t()]
        defyield :browsing
        defyield :results, params: [products: [Product.t()], total: integer()]
      end
  """
  defmacro defspindle(name, do: block) do
    spindle_name =
      case name do
        {atom_name, _meta, nil} when is_atom(atom_name) -> atom_name
        {:__aliases__, _meta, segments} -> List.last(segments)
      end

    spindle_atom = Module.concat(__CALLER__.module, spindle_name)

    Module.put_attribute(__CALLER__.module, :current_spindle, spindle_atom)

    quote do
      @pm_spindles unquote(spindle_atom)
      unquote(block)
      Module.delete_attribute(__MODULE__, :current_spindle)
    end
  end

  @doc """
  Declare a LiveView event routed to the current spindle.

  Without params, the spindle receives `{event_name, params}` (standard
  LiveView convention).

  With params and a struct name, a typed event struct is generated and
  the spindle receives it directly — enabling typed receive-side
  pattern matching.

  ## Syntax

      defevent "event_name"
      defevent "event_name", StructName, params: [field: type(), ...]
  """
  defmacro defevent(event_name) when is_binary(event_name) do
    build_defevent(event_name, nil, [], __CALLER__)
  end

  defmacro defevent(event_name, opts) when is_list(opts) do
    params = Keyword.get(opts, :params)
    build_defevent(event_name, nil, params || [], __CALLER__)
  end

  defmacro defevent(event_name, struct_name, opts) when is_list(opts) do
    params = Keyword.get(opts, :params)
    struct_atom = resolve_struct_name(struct_name)

    build_defevent(event_name, struct_atom, params || [], __CALLER__)
  end

  defp resolve_struct_name({:__aliases__, _meta, segments}), do: List.last(segments)
  defp resolve_struct_name({atom_name, _meta, nil}) when is_atom(atom_name), do: atom_name
  defp resolve_struct_name(atom) when is_atom(atom), do: atom

  defp build_defevent(event_name, struct_name, params, caller) do
    spindle = Module.get_attribute(caller.module, :current_spindle)

    unless spindle do
      raise CompileError,
        description: "defevent outside a defspindle block",
        file: caller.file
    end

    event = %{
      event: clean_event_name(event_name),
      spindle: spindle,
      struct_name: struct_name,
      params: params
    }

    escaped = Macro.escape(event)

    quote do
      @pm_events unquote(escaped)
    end
  end

  @doc """
  Declare a yield from the current spindle to the LiveView.

  ## Syntax

      defyield :tag
      defyield :tag, params: [field: type(), ...]
  """
  defmacro defyield(tag, opts \\ []) when is_atom(tag) do
    params = Keyword.get(opts, :params)

    yield = %{
      spindle: get_spindle!(__CALLER__),
      tag: tag,
      params: params || []
    }

    escaped = Macro.escape(yield)

    quote do
      @pm_yields unquote(escaped)
    end
  end

  defp get_spindle!(caller) do
    case Module.get_attribute(caller.module, :current_spindle) do
      nil ->
        raise CompileError,
          description: "defyield outside a defspindle block",
          file: caller.file

      spindle ->
        spindle
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    events = Module.get_attribute(env.module, :pm_events) |> Enum.reverse()
    yields = Module.get_attribute(env.module, :pm_yields) |> Enum.reverse()

    validate_events!(events, env)
    validate_yields!(yields, env)

    spindle_modules = generate_spindle_modules(env.module, yields)
    event_struct_modules = generate_event_struct_modules(env.module, events)
    introspection = generate_introspection(events, yields)
    event_list = generate_event_list(env.module, events)

    quote do
      unquote_splicing(spindle_modules)
      unquote_splicing(event_struct_modules)
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

    Enum.each(events, fn %{event: event} ->
      unless is_binary(event) and byte_size(event) > 0 do
        raise CompileError,
          description: "defevent event name must be a non-empty string",
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

  defp generate_spindle_modules(_protocol_module, yields) do
    yields
    |> Enum.group_by(& &1.spindle)
    |> Enum.map(fn {spindle_module, spindle_yields} ->
      struct_defs =
        Enum.flat_map(spindle_yields, fn
          %{params: []} -> []
          y -> [generate_yield_struct(spindle_module, y)]
        end)

      yield_fns = Enum.map(spindle_yields, &generate_yield_fn(spindle_module, &1))

      quote do
        defmodule unquote(spindle_module) do
          @moduledoc false
          unquote_splicing(struct_defs)
          unquote_splicing(yield_fns)
        end
      end
    end)
  end

  defp generate_yield_struct(spindle_module, %{tag: tag, params: params}) do
    struct_name = to_pascal_case(tag)
    struct_module = Module.concat(spindle_module, struct_name)

    fields = Enum.map(params, fn {name, _type} -> name end)
    field_defaults = Enum.map(fields, &{&1, nil})
    type_spec = Enum.map(params, fn {name, type} -> {name, type} end)

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

  defp generate_yield_fn(_spindle_module, %{tag: tag, params: []}) do
    quote do
      @spec unquote(tag)() :: Skuld.Comp.Types.computation()
      def unquote(tag)() do
        Skuld.Effects.Yield.yield(unquote(tag))
      end
    end
  end

  defp generate_yield_fn(spindle_module, %{tag: tag, params: params}) do
    struct_name = to_pascal_case(tag)
    struct_module = Module.concat(spindle_module, struct_name)
    field_names = Enum.map(params, fn {name, _type} -> name end)

    fetch_bindings =
      Enum.map(field_names, fn name ->
        var = Macro.var(name, nil)

        quote do
          unquote(var) = Keyword.fetch!(opts, unquote(name))
        end
      end)

    field_kvs =
      Enum.map(field_names, fn name ->
        {name, Macro.var(name, nil)}
      end)

    quote do
      @spec unquote(tag)(keyword()) :: Skuld.Comp.Types.computation()
      def unquote(tag)(opts) do
        unquote_splicing(fetch_bindings)
        struct = struct(unquote(struct_module), unquote(field_kvs))
        Skuld.Effects.Yield.yield(struct)
      end
    end
  end

  defp generate_event_struct_modules(_protocol_module, events) do
    events
    |> Enum.filter(fn %{struct_name: sn} -> sn != nil end)
    |> Enum.map(fn %{spindle: spindle, struct_name: struct_name, params: params} ->
      struct_module = Module.concat(spindle, struct_name)

      fields = Enum.map(params, fn {name, _type} -> name end)
      field_defaults = Enum.map(fields, &{&1, nil})
      type_spec = Enum.map(params, fn {name, type} -> {name, type} end)

      quote do
        defmodule unquote(struct_module) do
          @moduledoc false

          @type t :: %__MODULE__{
                  unquote_splicing(type_spec)
                }

          defstruct unquote(field_defaults)
        end
      end
    end)
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
      Enum.map(events, fn %{
                            event: event,
                            spindle: spindle,
                            struct_name: struct_name,
                            params: params
                          } ->
        {event, spindle, struct_name, params}
      end)

    escaped = Macro.escape(entries)

    quote do
      @doc false
      def __pm_events__, do: unquote(escaped)
    end
  end

  @doc false
  def to_pascal_case(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(fn s -> String.capitalize(s) end)
    |> String.to_atom()
  end

  defp clean_event_name(event) when is_binary(event), do: event
end
