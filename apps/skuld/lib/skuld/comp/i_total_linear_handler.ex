defmodule Skuld.Comp.ITotalLinearHandler do
  @moduledoc """
  Behaviour for effect operation handlers that are provably total and linear.

  A handler is **total** if it produces a value for every possible input —
  it never diverges, never throws an exception, and never raises an effect.
  A handler is **linear** if it has use-once semantics — the handler always
  either returns normally or the computation ends.

  When both properties hold, the `comp` macro can emit an optimised call
  path that skips continuation allocation and CPS indirection:

      {value, env2} = handler.(args, env)
      comp2 = f.(value)
      call(comp2, env2, k)

  ## Example

      defmodule MyTotalLinearEffect do
        @behaviour Skuld.Comp.ITotalLinearHandler

        @total [:get]
        @linear [:get]

        @impl Skuld.Comp.ITotalLinearHandler
        def handle(:get, env) do
          {Env.get_state!(env, @key), env}
        end
      end

  ## See Also

  - `Skuld.Comp.IHandle` — the general 3-arity handler behaviour
  """
  @callback handle(args :: term(), env :: Skuld.Comp.Types.env()) ::
              {Skuld.Comp.Types.result(), Skuld.Comp.Types.env()}
end
