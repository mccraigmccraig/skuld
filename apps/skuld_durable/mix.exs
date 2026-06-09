defmodule Skuld.Durable.MixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_durable,
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
        main: "SerializableCoroutine",
        umbrella_home: "https://hexdocs.pm/skuld/architecture.html",
        extras: [
          "docs/effects/effectlogger.md"
        ],
        groups_for_modules: [
          Durable: [
            Skuld.SerializableCoroutine,
            Skuld.Effects.EffectLogger,
            Skuld.Effects.EffectLogger.Log,
            Skuld.Effects.EffectLogger.EffectLogEntry,
            Skuld.Effects.EffectLogger.EnvStateSnapshot
          ]
        ],
        nest_modules_by_prefix: [
          Skuld.Effects.EffectLogger
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
      skuld_concurrency_dep(),
      {:jason, "~> 1.4"},
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

  @skuld_concurrency_version File.read!("../skuld_concurrency/VERSION") |> String.trim()

  defp skuld_concurrency_dep do
    if System.get_env("HEX_PUBLISH") == "true" do
      {:skuld_concurrency, "~> #{@skuld_concurrency_version}"}
    else
      {:skuld_concurrency, in_umbrella: true}
    end
  end

  defp description do
    "Durable execution for Skuld: SerializableCoroutine and EffectLogger for capturing and replaying effect logs."
  end

  defp package do
    [
      name: "skuld_durable",
      files: ~w(lib .formatter.exs mix.exs VERSION CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
