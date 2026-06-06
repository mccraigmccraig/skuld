defmodule Skuld.Concurrency.MixProject do
  use Mix.Project

  def project do
    [
      app: :skuld_concurrency,
      version: "0.1.0",
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
      {:skuld, in_umbrella: true}
    ]
  end

  defp description do
    "Cooperative concurrency for Skuld: FiberPool scheduler, Channel, Brook streaming, Yield, and AsyncCoroutine process bridging."
  end

  defp package do
    [
      name: "skuld_concurrency",
      files: ~w(lib .formatter.exs mix.exs),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/skuld"
      }
    ]
  end
end
