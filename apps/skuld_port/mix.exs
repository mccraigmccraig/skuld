defmodule Skuld.Port.MixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_port,
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
        main: "port",
        umbrella_home: "https://hexdocs.pm/skuld/architecture.html",
        extras: [
          "docs/effects/port.md",
          "docs/effects/effectful-facade.md",
          "docs/effects/adapter.md",
          "docs/effects/command-transaction.md"
        ],
        groups_for_extras: [
          Boundaries: [
            "docs/effects/port.md",
            "docs/effects/effectful-facade.md",
            "docs/effects/adapter.md",
            "docs/effects/command-transaction.md"
          ]
        ],
        groups_for_modules: [
          Port: [
            Skuld.Effects.Port
          ],
          Facade: [
            Skuld.Effects.Port.EffectfulFacade
          ],
          Adapter: [
            Skuld.Adapter,
            Skuld.Adapter.EffectfulContract
          ],
          Operations: [
            Skuld.Effects.Command,
            Skuld.Effects.Transaction
          ]
        ],
        nest_modules_by_prefix: [
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
      skuld_dep(),
      {:double_down, "~> 0.59.0"},
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
    "Port effect and adapter bridge for Skuld: dispatch blocking calls to pluggable backends and bridge effectful implementations to plain Elixir interfaces."
  end

  defp package do
    [
      name: "skuld_port",
      files: ~w(lib .formatter.exs mix.exs VERSION CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
