# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

config :chatchat_broker,
  ecto_repos: [ChatchatBroker.Repo]

config :chatchat_web, ChatchatWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: ChatchatWeb.ErrorJSON], layout: false],
  pubsub_server: ChatchatWeb.PubSub

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
#
