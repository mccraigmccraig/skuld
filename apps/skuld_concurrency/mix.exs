defmodule Skuld.Concurrency.MixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_concurrency,
      build_path: "../../_build",
      deps_path: "../../deps",
      config_path: "../../config/config.exs",
      lockfile: "../../mix.lock",
      version: File.read!("VERSION") |> String.trim(),
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
        umbrella_home: "https://hexdocs.pm/skuld/architecture.html",
        extras: [
          "README.md",
          "docs/effects/coroutine.md",
          "docs/effects/fiberpool.md",
          "docs/effects/channel-brook.md",
          "docs/effects/async-coroutine.md",
          "../skuld/docs/recipes/liveview.md",
          "../skuld/docs/recipes/batch-loading.md"
        ],
        groups_for_extras: [
          Introduction: [
            "README.md"
          ],
          "Coroutines & Concurrency": [
            "docs/effects/coroutine.md",
            "docs/effects/fiberpool.md",
            "docs/effects/channel-brook.md",
            "docs/effects/async-coroutine.md"
          ],
          Recipes: [
            "../skuld/docs/recipes/liveview.md",
            "../skuld/docs/recipes/batch-loading.md"
          ]
        ],
        groups_for_modules: [
          Coroutine: [
            Skuld.Coroutine,
            Skuld.Coroutine.PageMachine,
            Skuld.Coroutine.Handle,
            Skuld.Coroutine.Pending,
            Skuld.Coroutine.Completed,
            Skuld.Coroutine.Errored,
            Skuld.Coroutine.Cancelled,
            Skuld.Coroutine.InternalSuspended,
            Skuld.Coroutine.ExternalSuspended,
            Skuld.Coroutine.ForeignSuspended,
            Skuld.Coroutine.ForeignSuspensions,
            Skuld.Coroutine.Error
          ],
          Scheduler: [
            Skuld.Effects.FiberPool,
            Skuld.FiberPool.Main,
            Skuld.FiberPool.Scheduler,
            Skuld.FiberPool.BatchExecutor,
            Skuld.FiberPool.Batching,
            Skuld.FiberPool.FiberPoolState,
            Skuld.FiberPool.ChannelCoordinationState,
            Skuld.FiberPool.PendingWork,
            Skuld.FiberPool.Tasks
          ],
          Streaming: [
            Skuld.Effects.Channel,
            Skuld.Effects.Brook
          ],
          Async: [
            Skuld.AsyncCoroutine,
            Skuld.Effects.Task
          ],
          CrossPlatform: [
            Skuld.ForeignResolver,
            Skuld.Comp.InternalSuspend
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
      skuld_dep(),
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  @skuld_version File.read!("../skuld/VERSION") |> String.trim()

  defp skuld_dep do
    if System.get_env("HEX_PUBLISH") == "true" do
      {:skuld, "~> #{@skuld_version}"}
    else
      {:skuld, in_umbrella: true}
    end
  end

  defp description do
    "Cooperative concurrency for Skuld: FiberPool scheduler, Channel, Brook streaming, Yield, and AsyncCoroutine process bridging."
  end

  defp package do
    [
      name: "skuld_concurrency",
      files: ~w(lib .formatter.exs mix.exs README.md VERSION CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
