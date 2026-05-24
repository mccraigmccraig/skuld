defmodule Skuld.Test.Doubler do
  @moduledoc false
  defstruct []
  def new, do: %__MODULE__{}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(_resolver, suspends, continuation) do
      resolved = Map.new(suspends, &{&1.id, &1.payload * 2})
      continuation.(resolved)
    end
  end
end

defmodule Skuld.Test.Adder do
  @moduledoc false
  defstruct [:amount]
  def new(amount), do: %__MODULE__{amount: amount}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(resolver, suspends, continuation) do
      resolved = Map.new(suspends, &{&1.id, &1.payload + resolver.amount})
      continuation.(resolved)
    end
  end
end

defmodule Skuld.Test.MultiRound do
  @moduledoc false
  defstruct [:round]
  def new, do: %__MODULE__{round: 1}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(resolver, suspends, continuation) do
      {to_resolve, _rest} = Enum.split(suspends, max(1, div(length(suspends), 2)))

      values =
        case resolver.round do
          1 -> Enum.map(to_resolve, &{&1.id, &1.payload * 10})
          2 -> Enum.map(to_resolve, &{&1.id, &1.payload * 100})
          _ -> Enum.map(to_resolve, &{&1.id, &1.payload})
        end

      continuation.(Map.new(values))
    end
  end
end

defmodule Skuld.Test.Mapper do
  @moduledoc false
  defstruct [:fun]
  def new(fun), do: %__MODULE__{fun: fun}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(resolver, suspends, continuation) do
      resolved = Map.new(suspends, &{&1.id, resolver.fun.(&1.payload)})
      continuation.(resolved)
    end
  end
end
