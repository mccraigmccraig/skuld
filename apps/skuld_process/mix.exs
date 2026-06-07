defmodule Skuld.Process.MixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_process,
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
        groups_for_modules: [
          Process: [
            Skuld.Effects.Parallel,
            Skuld.Effects.AtomicState
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
    "Multi-process execution for Skuld: Task, Parallel, and AtomicState effects."
  end

  defp package do
    [
      name: "skuld_process",
      files: ~w(lib .formatter.exs mix.exs VERSION CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
