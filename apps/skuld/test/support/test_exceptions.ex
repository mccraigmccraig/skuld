# credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
defmodule Skuld.Test.NotFoundError do
  @moduledoc """
  Test exception for verifying IThrowable protocol behavior.
  """
  defexception [:entity, :id]

  @impl true
  def message(%{entity: entity, id: id}) do
    "#{entity} not found: #{id}"
  end
end

defimpl Skuld.Comp.IThrowable, for: Skuld.Test.NotFoundError do
  def unwrap(%{entity: entity, id: id}), do: {:not_found, entity, id}
end
