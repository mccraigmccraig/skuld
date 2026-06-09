defmodule Skuld.MixProject do
  use Mix.Project

  @version File.read!(Path.join(__DIR__, "../../VERSION")) |> String.trim()

  def project do
    [
      app: :skuld,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: [plt_add_apps: [:mix, :credo]],
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/mccraigmccraig/skuld",
      homepage_url: "https://github.com/mccraigmccraig/skuld",
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/why.md",
          "docs/what.md",
          "docs/getting-started.md",
          "docs/syntax.md",
          "docs/quick-reference.md",
          "docs/performance.md",
          "docs/architecture.md",
          "docs/effects/state-reader-writer.md",
          "docs/effects/throw-bracket.md",
          "docs/effects/fresh-random.md",
          "docs/effects/fxlist.md",
          "docs/effects/yield.md",
          "docs/recipes/hexagonal-architecture.md",
          "docs/recipes/property-testing.md",
          "docs/recipes/handler-stacks.md",
          "docs/recipes/liveview.md",
          "docs/recipes/durable-computation.md",
          "docs/recipes/batch-loading.md",
          "docs/internals.md",
          "docs/reference.md"
        ],
        groups_for_extras: [
          Introduction: [
            "README.md",
            "docs/why.md",
            "docs/what.md",
            "docs/getting-started.md",
            "docs/syntax.md",
            "docs/quick-reference.md",
            "docs/performance.md",
            "docs/architecture.md"
          ],
          "Foundational Effects": [
            "docs/effects/state-reader-writer.md",
            "docs/effects/throw-bracket.md",
            "docs/effects/fresh-random.md",
            "docs/effects/fxlist.md",
            "docs/effects/yield.md"
          ],
          Recipes: [
            "docs/recipes/hexagonal-architecture.md",
            "docs/recipes/property-testing.md",
            "docs/recipes/handler-stacks.md",
            "docs/recipes/liveview.md",
            "docs/recipes/durable-computation.md",
            "docs/recipes/batch-loading.md"
          ],
          "Under the Hood": [
            "docs/internals.md",
            "docs/reference.md"
          ]
        ],
        groups_for_modules: [
          Core: [
            Skuld,
            Skuld.Comp,
            Skuld.Syntax
          ],
          "Foundational Effects": [
            Skuld.Effects.State,
            Skuld.Effects.Reader,
            Skuld.Effects.Writer,
            Skuld.Effects.Throw,
            Skuld.Effects.Bracket,
            Skuld.Effects.Fresh,
            Skuld.Effects.Random,
            Skuld.Effects.FxList,
            Skuld.Effects.FxFasterList,
            Skuld.Effects.Yield
          ],
          "Core Types": [
            Skuld.Comp.Env,
            Skuld.Comp.Types,
            Skuld.Comp.ExternalSuspend,
            Skuld.Comp.ForeignSuspend,
            Skuld.Comp.Throw,
            Skuld.Comp.Cancelled
          ],
          Protocols: [
            Skuld.Comp.ISentinel,
            Skuld.Comp.IHandle,
            Skuld.Comp.IInstall,
            Skuld.Comp.IIntercept,
            Skuld.Comp.IThrowable
          ],
          Exceptions: [
            Skuld.Comp.ThrowError,
            Skuld.Comp.UncaughtThrow,
            Skuld.Comp.UncaughtExit,
            Skuld.Comp.InvalidComputation,
            Skuld.Comp.MatchFailed
          ]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:uniq, "~> 0.6"},
      {:ecto, "~> 3.12", optional: true},
      {:mix_test_watch, "~> 1.4.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:gen_stage, "~> 1.2", only: [:dev, :test]},
      {:benchee, "~> 1.3", only: :dev}
    ]
  end

  defp description do
    "Core effect system for Elixir: write business logic as pure effect descriptions, swap handlers for testing. Provides the computation engine (Comp) and foundational effects (State, Reader, Writer, Throw, Yield). For coroutines, query batching, port/adapter boundaries, and database integration, see sibling packages."
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
