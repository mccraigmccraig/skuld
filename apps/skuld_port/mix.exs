defmodule Skuld.Port.MixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_port,
      version: File.read!("VERSION") |> String.trim(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/mccraigmccraig/skuld",
      homepage_url: "https://github.com/mccraigmccraig/skuld"
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
      {:double_down, "~> 0.58"}
    ]
  end

  defp description do
    "Port effect and adapter bridge for Skuld: dispatch blocking calls to pluggable backends and bridge effectful implementations to plain Elixir interfaces."
  end

  defp package do
    [
      name: "skuld_port",
      files: ~w(lib .formatter.exs mix.exs VERSION),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
