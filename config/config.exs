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

config :logger, level: :error

config :chatchat_broker,
  ecto_repos: [ChatchatBroker.Repo]

config :chatchat_auth,
  token_salt: "user authentication",
  max_age: 15 * 60

config :argon2_elixir,
  t_cost: 1,
  parallelism: 12

config :chatchat_tcp,
  redis_url: "redis://localhost:6379",
  metrics_server: [ip: {0, 0, 0, 0}, port: 9568],
  delivery: [max_concurrency: 64],
  admission: [
    pending_ttl: 60_000,
    delivery_window: 20_000,
    persistence_batch_size: 500,
    persistence_retry_interval: 1_000
  ],
  server: [transport_options: [ip: {0, 0, 0, 0}], port: 4040, read_timeout: 60_000],
  handler: [authentication_timeout: 5_000, max_frame_size: 8_192]

config :chatchat_web, ChatchatWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  live_view: [signing_salt: "chatchat-live-view"],
  render_errors: [formats: [json: ChatchatWeb.ErrorJSON], layout: false],
  pubsub_server: ChatchatWeb.PubSub

config :chatchat_web,
  prometheus_url: "http://localhost:9090",
  prometheus_tcp_job: "chatchat_tcp_local",
  redis_url: "redis://localhost:6379"

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
#
