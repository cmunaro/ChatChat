defmodule ChatChat.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      elixir: "1.20.4",
      listeners: [Phoenix.CodeReloader],
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      deps: deps()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end

  defp releases do
    [
      chatchat_web: [applications: [chatchat_web: :permanent]],
      chatchat_broker: [applications: [chatchat_broker: :permanent]],
      chatchat_tcp: [applications: [chatchat_tcp: :permanent]]
    ]
  end
end
