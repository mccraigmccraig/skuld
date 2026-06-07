defmodule Skuld.Repo.MixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_repo,
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
        main: "Repo",
        extras: [
          "docs/effects/repo.md"
        ],
        groups_for_modules: [
          Repo: [
            Skuld.Repo,
            Skuld.Repo.Contract,
            Skuld.Repo.Effectful,
            Skuld.Repo.Ecto,
            Skuld.Repo.InMemory,
            Skuld.Repo.OpenInMemory,
            Skuld.Repo.Stub,
            Skuld.Repo.Test
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
      {:skuld, in_umbrella: true},
      {:skuld_port, in_umbrella: true},
      {:double_down, "~> 0.58"},
      {:ecto, "~> 3.12", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Ecto Repo integration for Skuld: effectful dispatch facade for standard Ecto Repo operations."
  end

  defp package do
    [
      name: "skuld_repo",
      files: ~w(lib .formatter.exs mix.exs VERSION CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
