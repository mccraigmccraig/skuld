# Compile-time macro for generating a Plain implementation of Port.Repo
# that delegates to a specific Ecto Repo module.
#
# ## Usage
#
#     defmodule MyApp.Repo.Port do
#       use Skuld.Effects.Port.Repo.Ecto, repo: MyApp.Repo
#     end
#
#     # Then wire it up:
#     comp
#     |> Port.with_handler(%{Port.Repo => MyApp.Repo.Port})
#     |> Comp.run!()
#
if Code.ensure_loaded?(Ecto) do
  defmodule Skuld.Effects.Port.Repo.Ecto do
    @moduledoc """
    Macro for generating a `Port.Repo.Plain` implementation that delegates
    to a specific Ecto Repo module.

    Each operation in the `Port.Repo` contract is implemented by calling
    the corresponding function on the configured Repo module with the
    same arguments.

    ## Usage

        defmodule MyApp.Repo.Port do
          use Skuld.Effects.Port.Repo.Ecto, repo: MyApp.Repo
        end

    This generates a module satisfying `Skuld.Effects.Port.Repo.Plain`
    with functions like:

        def insert(changeset), do: MyApp.Repo.insert(changeset)
        def update(changeset), do: MyApp.Repo.update(changeset)
        # ... etc.

    ## Handler Installation

        alias Skuld.Effects.Port

        comp
        |> Port.with_handler(%{Port.Repo => MyApp.Repo.Port})
        |> Comp.run!()
    """

    defmacro __using__(opts) do
      repo = Keyword.fetch!(opts, :repo)

      operations = Skuld.Effects.Port.Repo.__port_operations__()

      delegations =
        Enum.map(operations, fn %{name: name, params: params, arity: arity} ->
          param_vars = Enum.map(params, fn p -> Macro.var(p, nil) end)

          quote do
            @impl true
            def unquote(name)(unquote_splicing(param_vars)) do
              unquote(repo).unquote(name)(unquote_splicing(param_vars))
            end

            defoverridable [{unquote(name), unquote(arity)}]
          end
        end)

      quote do
        @behaviour Skuld.Effects.Port.Repo.Plain

        unquote_splicing(delegations)
      end
    end
  end
end
