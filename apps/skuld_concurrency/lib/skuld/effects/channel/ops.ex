defmodule Skuld.Effects.Channel.Ops do
  @moduledoc false

  alias Skuld.Comp
  alias Skuld.Effects.Channel

  @spec create(Comp.Types.env(), non_neg_integer()) :: {Channel.Handle.t(), Comp.Types.env()}
  def create(env, capacity) do
    Comp.call(Channel.new(capacity), env, &Comp.identity_k/2)
  end

  @spec put_and_close(Comp.Types.env(), Channel.Handle.t(), term()) :: Comp.Types.env()
  def put_and_close(env, %Channel.Handle{} = handle, value) do
    {:ok, env} = Comp.call(Channel.put(handle, value), env, &Comp.identity_k/2)
    {:ok, env} = Comp.call(Channel.close(handle), env, &Comp.identity_k/2)
    env
  end
end
