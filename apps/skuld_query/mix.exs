defmodule Skuld.QueryMixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_query,
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
          "docs/effects/query.md",
          "../skuld/docs/recipes/batch-loading.md"
        ],
        groups_for_extras: [
          Introduction: [
            "README.md"
          ],
          Effects: [
            "docs/effects/query.md"
          ],
          Recipes: [
            "../skuld/docs/recipes/batch-loading.md"
          ]
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
      skuld_dep(),
      skuld_concurrency_dep(),
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

  @skuld_concurrency_version File.read!("../skuld_concurrency/VERSION") |> String.trim()

  defp skuld_concurrency_dep do
    if System.get_env("HEX_PUBLISH") == "true" do
      {:skuld_concurrency, "~> #{@skuld_concurrency_version}"}
    else
      {:skuld_concurrency, in_umbrella: true}
    end
  end

  defp description do
    "Query batching system for Skuld: typed batchable fetch contracts with automatic concurrent batching."
  end

  defp package do
    [
      name: "skuld_query",
      files: ~w(lib .formatter.exs mix.exs README.md VERSION CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
