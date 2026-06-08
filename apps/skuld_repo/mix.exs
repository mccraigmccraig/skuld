defmodule Skuld.Repo.MixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_repo,
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
      skuld_dep(),
      skuld_port_dep(),
      {:double_down, "~> 0.58"},
      {:ecto, "~> 3.12"},
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

  @skuld_port_version File.read!("../skuld_port/VERSION") |> String.trim()

  defp skuld_port_dep do
    if System.get_env("HEX_PUBLISH") == "true" do
      {:skuld_port, "~> #{@skuld_port_version}"}
    else
      {:skuld_port, in_umbrella: true}
    end
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
