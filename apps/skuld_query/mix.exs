defmodule Skuld.QueryMixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_query,
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
        main: "Query",
        extras: [
          "docs/effects/query.md"
        ],
        groups_for_modules: [
          Query: [
            Skuld.Query,
            Skuld.QueryContract,
            Skuld.Query.Contract,
            Skuld.Query.Cache,
            Skuld.Query.QueryBlock
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

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/integration"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:skuld, in_umbrella: true},
      {:skuld_concurrency, in_umbrella: true},
      {:double_down, "~> 0.58"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Query batching system for Skuld: typed batchable fetch contracts with automatic concurrent batching."
  end

  defp package do
    [
      name: "skuld_query",
      files: ~w(lib .formatter.exs mix.exs VERSION CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
