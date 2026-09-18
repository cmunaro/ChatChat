defmodule ChatchatClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :chatchat_client,
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
      mod: {ChatchatClient.Application, []},
      extra_applications: [:inets, :logger, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, "~> 3.14"},
      {:jason, "~> 1.4"}
    ]
  end
end
