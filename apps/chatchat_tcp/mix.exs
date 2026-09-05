defmodule ChatchatTcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :chatchat_tcp,
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
      mod: {ChatchatTcp.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:chatchat_auth, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:thousand_island, "~> 1.5"}
    ]
  end
end
