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
      {:skuld_concurrency, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end

  defp description do
    "Durable execution for Skuld: SerializableCoroutine and EffectLogger for capturing and replaying effect logs."
  end

  defp package do
    [
      name: "skuld_durable",
      files: ~w(lib .formatter.exs mix.exs VERSION),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
