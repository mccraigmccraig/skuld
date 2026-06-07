defmodule Skuld.Durable.MixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_durable,
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
      {:skuld, in_umbrella: true},
      {:skuld_concurrency, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
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
