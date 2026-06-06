defmodule Skuld.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.0.0",
      start_permanent: false,
      deps: deps()
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:mix_test_watch, "~> 1.4.0", only: [:dev, :test], runtime: false},
      {:gen_stage, "~> 1.2", only: [:dev, :test]},
      {:benchee, "~> 1.3", only: :dev}
    ]
  end
end
