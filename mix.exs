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
            Skuld.Fiber
          ],
          "Persistence & Data": [
            Skuld.Effects.DB,
            Skuld.Effects.DBTransaction,
            Skuld.Effects.ChangesetPersist,
            Skuld.Effects.Port,
            Skuld.Effects.Command,
            Skuld.Effects.ChangeEvent,
            Skuld.Effects.EventAccumulator,
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
            Skuld.Comp.IThrowable,
            Skuld.Effects.EventAccumulator.IEvent
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
