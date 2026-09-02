defmodule ChatchatWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :chatchat_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ChatchatWeb.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:chatchat_broker, in_umbrella: true},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:open_api_spex, "~> 3.22"},
      {:phoenix, "~> 1.8"}
    ]
  end
end
