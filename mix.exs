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
      dialyzer: [plt_add_apps: [:mix]],
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
          "docs/pain-points.md",
          "docs/getting-started.md",
          "docs/quick-reference.md",
          "docs/architecture.md",
          "docs/syntax.md",
          "docs/testing.md",
          "docs/effects/state-environment.md",
          "docs/effects/error-handling.md",
          "docs/effects/value-generation.md",
          "docs/effects/collections.md",
          "docs/effects/concurrency.md",
          "docs/effects/persistence.md",
          "docs/effects/repo.md",
          "docs/effects/external-integration.md",
          "docs/advanced/yield.md",
          "docs/advanced/fibers-concurrency.md",
          "docs/advanced/query-batching.md",
          "docs/advanced/effect-logger.md",
          "docs/recipes/hexagonal-architecture.md",
          "docs/recipes/decider-pattern.md",
          "docs/recipes/handler-stacks.md",
          "docs/recipes/liveview.md",
          "docs/recipes/batch-loading.md",
          "docs/internals.md",
          "docs/reference.md",
          "docs/research/performance-investigation.md"
        ],
        groups_for_extras: [
          Introduction: [
            "README.md",
            "docs/why.md",
            "docs/what.md",
            "docs/pain-points.md",
            "docs/getting-started.md",
            "docs/quick-reference.md",
            "docs/architecture.md",
            "docs/syntax.md"
          ],
          "Core Concepts": [
            "docs/testing.md"
          ],
          Effects: [
            "docs/effects/state-environment.md",
            "docs/effects/error-handling.md",
            "docs/effects/value-generation.md",
            "docs/effects/collections.md",
            "docs/effects/concurrency.md",
            "docs/effects/persistence.md",
            "docs/effects/repo.md",
            "docs/effects/external-integration.md",
            "docs/advanced/yield.md",
            "docs/advanced/fibers-concurrency.md",
            "docs/advanced/query-batching.md",
            "docs/advanced/effect-logger.md"
          ],
          Patterns: [
            "docs/recipes/hexagonal-architecture.md",
            "docs/recipes/decider-pattern.md",
            "docs/recipes/handler-stacks.md",
            "docs/recipes/liveview.md",
            "docs/recipes/batch-loading.md"
          ],
          Internals: [
            "docs/internals.md",
            "docs/reference.md"
          ],
          Research: [
            "docs/research/performance-investigation.md"
          ]
        ],
        groups_for_modules: [
          Core: [
            Skuld,
            Skuld.Comp,
            Skuld.Syntax,
            Skuld.AsyncComputation
          ],
          "State & Environment": [
            Skuld.Effects.State,
            Skuld.Effects.Reader,
            Skuld.Effects.Writer
          ],
          "Control Flow": [
            Skuld.Effects.Throw,
            Skuld.Effects.Bracket,
            Skuld.Effects.Yield
          ],
          "Collection Iteration": [
            Skuld.Effects.FxList,
            Skuld.Effects.FxFasterList
          ],
          "Value Generation": [
            Skuld.Effects.Fresh,
            Skuld.Effects.Random
          ],
          Concurrency: [
            Skuld.Effects.AtomicState,
            Skuld.Effects.FiberPool,
            Skuld.Effects.Channel,
            Skuld.Effects.Brook,
            Skuld.Effects.Parallel,
            Skuld.Effects.Task,
            Skuld.Coroutine
          ],
          "Persistence & Data": [
            Skuld.Effects.Transaction,
            Skuld.Query.Contract,
            Skuld.Effects.Port,
            Skuld.Effects.Command,
            Skuld.Repo,
            Skuld.Data.Change
          ],
          "Replay & Logging": [
            Skuld.Effects.EffectLogger,
            Skuld.Effects.EffectLogger.Log
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
    """
    An effectful programming framework for Elixir.

    Write business logic as pure effect descriptions — database access,
    concurrency, error handling, and workflow orchestration — then swap handlers
    between production and deterministic test implementations. Built on algebraic
    effects with cooperative fibers, automatic N+1 query batching, hexagonal
    architecture support, and durable serialisable workflows.
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
