defmodule Skuld.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

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
          "docs/effects/state-reader-writer.md",
          "docs/effects/throw-bracket.md",
          "docs/effects/fresh-random.md",
          "docs/effects/fxlist.md",
          "docs/effects/command-transaction.md",
          "docs/effects/yield.md",
          "docs/effects/coroutine.md",
          "docs/effects/fiberpool.md",
          "docs/effects/channel-brook.md",
          "docs/effects/async-coroutine.md",
          "docs/effects/effectlogger.md",
          "docs/effects/port.md",
          "docs/effects/effectful-facade.md",
          "docs/effects/adapter.md",
          "docs/effects/repo.md",
          "docs/effects/query.md",
          "docs/recipes/hexagonal-architecture.md",
          "docs/recipes/property-testing.md",
          "docs/recipes/handler-stacks.md",
          "docs/recipes/liveview.md",
          "docs/recipes/decider-pattern.md",
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
            "docs/quick-reference.md"
          ],
          "Foundational Effects": [
            "docs/effects/state-reader-writer.md",
            "docs/effects/throw-bracket.md",
            "docs/effects/fresh-random.md",
            "docs/effects/fxlist.md",
            "docs/effects/command-transaction.md"
          ],
          "Coroutines & Concurrency": [
            "docs/effects/yield.md",
            "docs/effects/coroutine.md",
            "docs/effects/fiberpool.md",
            "docs/effects/channel-brook.md",
            "docs/effects/async-coroutine.md",
            "docs/effects/effectlogger.md"
          ],
          Boundaries: [
            "docs/effects/port.md",
            "docs/effects/effectful-facade.md",
            "docs/effects/adapter.md",
            "docs/effects/repo.md"
          ],
          "Cross-cutting": [
            "docs/effects/query.md"
          ],
          Recipes: [
            "docs/recipes/hexagonal-architecture.md",
            "docs/recipes/property-testing.md",
            "docs/recipes/handler-stacks.md",
            "docs/recipes/liveview.md",
            "docs/recipes/decider-pattern.md",
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
            Skuld.Syntax,
            Skuld.AsyncCoroutine,
            Skuld.Coroutine,
            Skuld.Adapter
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
            Skuld.Effects.Command,
            Skuld.Effects.Transaction,
            Skuld.Effects.Yield
          ],
          "Coroutines & Concurrency": [
            Skuld.Effects.FiberPool,
            Skuld.Effects.Channel,
            Skuld.Effects.Brook,
            Skuld.Effects.Parallel,
            Skuld.Effects.AtomicState,
            Skuld.Effects.Task,
            Skuld.Effects.EffectLogger
          ],
          Boundaries: [
            Skuld.Effects.Port,
            Skuld.Repo
          ],
          "Cross-cutting": [
            Skuld.Query.Contract
          ],
          "Core Types": [
            Skuld.Comp.Env,
            Skuld.Comp.Types,
            Skuld.Comp.ExternalSuspend,
            Skuld.Comp.InternalSuspend,
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
        ],
        nest_modules_by_prefix: [
          Skuld.Effects.EffectLogger,
          Skuld.Effects.Transaction
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
      {:double_down, "~> 0.58"},
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
    "Effectful programming for Elixir: write business logic as pure effect descriptions, swap handlers for testing. Built on algebraic effects and bundled with a substantial library of effects including cooperative coroutines, automatic query batching, and DoubleDown boundary integration."
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
