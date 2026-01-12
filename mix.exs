defmodule PriceHistory.MixProject do
  use Mix.Project

  def project do
    [
      app: :price_history,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {PriceHistory.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ethers, "~> 0.5.0"},
      {:jason, "~> 1.4"},
      {:dotenvy, "~> 0.8.0"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.4"},
      {:plug_cowboy, "~> 2.5"}
    ]
  end
end
