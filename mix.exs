defmodule Skuld.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :skuld,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/mccraigmccraig/skuld",
      homepage_url: "https://github.com/mccraigmccraig/skuld",
      docs: [
        main: "readme",
        extras: ["README.md"],
        groups_for_modules: [
          Core: [
            Skuld.Comp,
            Skuld.Syntax
          ],
          "Standard Effects": [
            Skuld.Effects.Reader,
            Skuld.Effects.State,
            Skuld.Effects.Writer,
            Skuld.Effects.Throw,
            Skuld.Effects.Fresh
          ],
          "Control Effects": [
            Skuld.Effects.Yield,
            Skuld.Effects.Bracket
          ],
          "Collection Effects": [
            Skuld.Effects.FxList,
            Skuld.Effects.FxFasterList
          ],
          "Database Effects": [
            Skuld.Effects.DBTransaction,
            Skuld.Effects.DBTransaction.Ecto,
            Skuld.Effects.DBTransaction.Noop,
            Skuld.Effects.EctoPersist,
            Skuld.Effects.Port
          ],
          "Event & Logging Effects": [
            Skuld.Effects.EventAccumulator,
            Skuld.Effects.EffectLogger
          ],
          Internals: [
            ~r/^Skuld\.Comp\..*/
          ]
        ],
        nest_modules_by_prefix: [
          Skuld.Effects.DBTransaction,
          Skuld.Effects.EffectLogger,
          Skuld.Effects.EctoPersist,
          Skuld.Effects.EventAccumulator
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:uniq, "~> 0.6"},
      {:ecto, "~> 3.12", optional: true},
      {:mix_test_watch, "~> 1.4.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Skuld: Evidence-passing algebraic effects for Elixir.

    A clean, efficient implementation of algebraic effects using evidence-passing
    style with CPS for control effects. Supports scoped handlers, coroutines via
    Yield, and composable effect stacks.
    """
  end

  defp package do
    [
      name: "skuld",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE VERSION),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
