defmodule Skuld.Test.Doubler do
  @moduledoc false
  defstruct [:value]
  def new(value), do: %__MODULE__{value: value}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(_payload, suspends, continuation) do
      resolved = Map.new(suspends, &{&1.id, &1.payload.value * 2})
      continuation.(resolved)
    end
  end
end

defmodule Skuld.Test.Adder do
  @moduledoc false
  defstruct [:value]
  def new(value), do: %__MODULE__{value: value}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(_payload, suspends, continuation) do
      resolved = Map.new(suspends, &{&1.id, &1.payload.value + 100})
      continuation.(resolved)
    end
  end
end

defmodule Skuld.Test.Mapper do
  @moduledoc false
  defstruct [:value]
  def new(value), do: %__MODULE__{value: value}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(_payload, suspends, continuation) do
      resolved = Map.new(suspends, &{&1.id, &1.payload.value})
      continuation.(resolved)
    end
  end
end

defmodule Skuld.Test.MultiRound do
  @moduledoc false
  defstruct [:value]
  def new(value), do: %__MODULE__{value: value}

  defimpl Skuld.ForeignResolver, for: __MODULE__ do
    def await_resolutions(_payload, suspends, continuation) do
      {to_resolve, _rest} = Enum.split(suspends, max(1, div(length(suspends), 2)))
      resolved = Map.new(to_resolve, &{&1.id, &1.payload.value * 10})
      continuation.(resolved)
    end
  end
end
